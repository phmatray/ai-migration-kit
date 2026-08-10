#!/usr/bin/env python3
"""Génère le dashboard exécutif d'une migration (migration/report.html).

Usage : report-dashboard.py <report.json> [-o report.html]

Entrées (report.json) : contenu du rapport (KPIs, valeur business, avant/après,
portes, next steps…). La couverture est lue depuis un cobertura.xml (chemin dans
le JSON) — jamais déclarée à la main. La capture est embarquée en data URI.
Sortie : document HTML autonome (double-cliquable, envoyable), thème clair/sombre,
palette validée (cf. dashboard d'audit du kit).
"""
import argparse
import base64
import html
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

PALETTE_LIGHT = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]
PALETTE_DARK = ["#3987e5", "#d95926", "#199e70", "#c98500"]


def esc(s):
    return html.escape(str(s), quote=True)


CONDITIONS = re.compile(r"\((\d+)/(\d+)\)")


def _conditions(line):
    """(branches couvertes, branches totales) d'une ligne — `condition-coverage="50% (1/2)"`.

    Une ligne sans branche n'en déclare pas : elle pèse 0/0 et ne participe donc pas au taux.
    """
    m = CONDITIONS.search(line.get("condition-coverage") or "")
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


def parse_cobertura(paths, excluded_prefixes, included_names=None):
    """Lit UN cobertura (chemin nu) ou PLUSIEURS (itérable de chemins) et les agrège.

    Sous Microsoft Testing Platform chaque projet de test écrit son propre rapport : le
    dashboard doit donc décrire l'union, pas le dernier fichier arrivé. Une classe vue par
    plusieurs rapports est comptée UNE fois, hits sommés ligne à ligne — deux projets qui
    exercent la même bibliothèque ne doivent ni la dupliquer dans le tableau, ni gonfler son
    dénominateur.

    ⚠ Les taux globaux sont RECALCULÉS sur les lignes fusionnées, jamais lus dans l'attribut
    `line-rate` de la racine. Mesuré : deux projets de test d'une même solution instrumentent
    la MÊME bibliothèque, donc chaque rapport déclare le total de lignes du produit entier.
    Combiner les taux racine — même pondérés par `lines-valid` — compte ce total deux fois et
    rend 35 % là où l'union en couvre 73 %. Le recalcul est aussi cohérent avec le tableau
    qu'il légende : même périmètre, mêmes exclusions.
    """
    if isinstance(paths, (str, Path)):
        paths = [paths]
    # Clé = nom COMPLET de la classe : deux namespaces peuvent porter le même nom court, et
    # les fusionner mélangerait deux classes distinctes. L'ordre d'insertion est l'ordre du
    # document, donc les ex æquo gardent l'ordre d'origine après le tri (stable).
    merged = {}
    for path in paths:
        root = ET.parse(path).getroot()
        for cls in root.iter("class"):
            name = cls.get("name")
            if "<" in name or "/" in name:
                continue
            if any(name.startswith(p) for p in excluded_prefixes):
                continue
            if included_names and name.split(".")[-1] not in included_names:
                continue
            by_line = merged.setdefault(name, {})
            for l in cls.findall(".//line"):
                slot = by_line.setdefault(l.get("number"), [0, 0, 0])
                covered, total = _conditions(l)
                slot[0] += int(l.get("hits"))
                # Le maximum, pas la somme : deux rapports qui couvrent LA MÊME branche
                # rendraient 2/2 sur une ligne qui n'en a qu'une de couverte. Le maximum
                # sous-estime quand ils en couvrent deux différentes — on préfère l'erreur
                # qui ne surestime jamais une couverture.
                slot[1], slot[2] = max(slot[1], covered), max(slot[2], total)
    classes, lines_covered, lines_total, br_covered, br_total = [], 0, 0, 0, 0
    for name, by_line in merged.items():
        covered = sum(1 for hits, _, _ in by_line.values() if hits > 0)
        total = len(by_line)
        lines_covered, lines_total = lines_covered + covered, lines_total + total
        br_covered += sum(c for _, c, _ in by_line.values())
        br_total += sum(t for _, _, t in by_line.values())
        classes.append({
            "name": name.split(".")[-1],
            "covered": covered,
            "total": total,
            "pct": round(100 * covered / total) if total else 0,
        })
    classes.sort(key=lambda c: -c["pct"])
    return {
        "classes": classes,
        "line_pct": round(100 * lines_covered / lines_total) if lines_total else 0,
        "branch_pct": round(100 * br_covered / br_total) if br_total else 0,
    }


def data_uri(path):
    ext = Path(path).suffix.lstrip(".").lower()
    mime = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "svg": "image/svg+xml"}[ext]
    return f"data:{mime};base64," + base64.b64encode(Path(path).read_bytes()).decode()


def hbar_chart(rows, aria, note, multi_hue=False):
    """rows: [{label, value(0..max), display, tip, hue?}] — barres horizontales SVG."""
    gutter, right_pad, width = 190, 70, 660
    scale = (width - gutter - right_pad) / max(r["value"] for r in rows)
    row_h, y = 34, 8
    parts = []
    for i, r in enumerate(rows):
        w = max(4, round(r["value"] * scale))
        hue = r.get("hue", i if multi_hue else 0) % 4
        parts.append(
            f'<rect x="{gutter}" y="{y}" width="{w}" height="18" rx="3" fill="var(--s{hue + 1})"'
            f' tabindex="0" data-tip="{esc(r["tip"])}"/>'
            f'<text x="{gutter - 8}" y="{y + 14}" text-anchor="end">{esc(r["label"])}</text>'
            f'<text class="val" x="{gutter + w + 6}" y="{y + 14}">{esc(r["display"])}</text>')
        y += row_h
    if note:
        parts.append(f'<text x="{gutter}" y="{y + 10}" fill="var(--muted)">{esc(note)}</text>')
        y += 26
    return (f'<svg viewBox="0 0 {width} {y + 4}" role="img" aria-label="{esc(aria)}">'
            f'<line class="axisline" x1="{gutter}" y1="0" x2="{gutter}" y2="{y - row_h + 26}"/>'
            + "".join(parts) + "</svg>")


def render(r):
    cov = parse_cobertura(r["coverage"]["cobertura"], r["coverage"].get("exclude", []),
                          r["coverage"].get("include"))
    kpis = "".join(
        f'<div class="tile"><div class="v">{esc(k["v"])}'
        + (f'<small>{esc(k["unit"])}</small>' if k.get("unit") else "")
        + f'</div><div class="l">{esc(k["label"])}</div></div>'
        for k in r["kpis"])
    business = "".join(
        f'<li><strong>{esc(b["strong"])}</strong> {esc(b["text"])}</li>' for b in r["business"])
    cov_rows = [{"label": c["name"], "value": c["pct"], "display": f'{c["pct"]} %',
                 "tip": f'{c["name"]} : {c["covered"]}/{c["total"]} lignes couvertes'}
                for c in cov["classes"]]
    cov_note = (f'Global : {cov["line_pct"]} % lignes · {cov["branch_pct"]} % branches'
                + (f' — {r["coverage"]["note"]}' if r["coverage"].get("note") else ""))
    cov_svg = hbar_chart(cov_rows, "Couverture de lignes par classe", cov_note)
    code_rows = [{"label": b["label"], "value": b["loc"], "display": str(b["loc"]),
                  "tip": b["tip"], "hue": i} for i, b in enumerate(r["code_bodies"])]
    code_svg = hbar_chart(code_rows, "Lignes de code par corps", r.get("code_note", ""), multi_hue=True)
    rows_ba = "".join(
        f'<tr><td>{esc(a)}</td><td>{esc(b)}</td><td class="win">{esc(c)}</td></tr>'
        for a, b, c in r["before_after"])
    gates = "".join(
        f'<li><span class="g">✓</span><span><strong>{esc(g["title"])}</strong> — {esc(g["text"])}'
        f' <code>{esc(g["commit"])}</code></span></li>' for g in r["gates"])
    steps = "".join(
        '<li><span class="box" aria-hidden="true"></span><span>'
        + ('<span class="owner">Décision</span> ' if s.get("owner") else "")
        + f'{esc(s["text"])}</span><span class="eff">{esc(s.get("effort", "—"))}</span></li>'
        for s in r["next_steps"])
    deferred = "".join(
        f'<li><strong>{esc(d["strong"])}</strong> — {esc(d["text"])}</li>' for d in r["deferred"])
    timeline = ""
    if r.get("phases"):
        ph_rows = [{"label": f'{p["phase"]}. {p["name"]}', "value": max(p["minutes"], 0.1),
                    "display": f'{p["minutes"]} min',
                    "tip": f'{p["name"]} : {p["start"]} → {p["end"]}', "hue": i}
                   for i, p in enumerate(r["phases"])]
        total = round(sum(p["minutes"] for p in r["phases"]))
        ph_svg = hbar_chart(
            ph_rows, "Minutes par phase du pipeline",
            f"Total : {total} min — dérivé des commits de porte (git), jamais chronométré à la main",
            multi_hue=True)
        timeline = ('<div class="card"><h2>Chronologie du pipeline</h2>'
                    '<p class="sub">Minutes par phase, mesurées depuis les commits de porte.</p>'
                    f'{ph_svg}</div>')
    lessons = ""
    if r.get("lessons"):
        lesson_items = "".join(
            f'<li><strong>{esc(l["strong"])}</strong> {esc(l["text"])}'
            + (f' <code>{esc(l["ref"])}</code>' if l.get("ref") else "") + "</li>"
            for l in r["lessons"])
        lessons = ('<div class="card"><h2>Leçons de la vague</h2>'
                   '<p class="sub">Ce que cette migration a appris au kit — rétropropagé à la source.</p>'
                   f'<ul class="value">{lesson_items}</ul></div>')
    shot = ""
    if r.get("screenshot"):
        s = r["screenshot"]
        shot = (f'<div class="card"><h2>Le produit, dans le navigateur</h2>'
                f'<p class="sub">{esc(s["caption"])}</p>'
                f'<img class="shot" src="{data_uri(s["path"])}" alt="{esc(s["alt"])}" /></div>')
    css_vars_light = "".join(f"--s{i + 1}: {c};" for i, c in enumerate(PALETTE_LIGHT))
    css_vars_dark = "".join(f"--s{i + 1}: {c};" for i, c in enumerate(PALETTE_DARK))

    return f"""<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Migration {esc(r["app"])} — rapport exécutif</title>
<style>
  :root {{ color-scheme: light; --plane:#f9f9f7; --surface:#fcfcfb; --ink:#0b0b0b; --ink-2:#52514e;
    --muted:#898781; --grid:#e1e0d9; --axis:#c3c2b7; --ring:rgba(11,11,11,0.10);
    {css_vars_light} --good-text:#006300; }}
  @media (prefers-color-scheme: dark) {{ :root:where(:not([data-theme="light"])) {{ color-scheme: dark;
    --plane:#0d0d0d; --surface:#1a1a19; --ink:#fff; --ink-2:#c3c2b7; --muted:#898781; --grid:#2c2c2a;
    --axis:#383835; --ring:rgba(255,255,255,0.10); {css_vars_dark} --good-text:#0ca30c; }} }}
  :root[data-theme="dark"] {{ color-scheme: dark;
    --plane:#0d0d0d; --surface:#1a1a19; --ink:#fff; --ink-2:#c3c2b7; --muted:#898781; --grid:#2c2c2a;
    --axis:#383835; --ring:rgba(255,255,255,0.10); {css_vars_dark} --good-text:#0ca30c; }}
  body {{ margin:0; background:var(--plane); color:var(--ink); font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif; }}
  .wrap {{ max-width:980px; margin:0 auto; padding:32px 20px 64px; display:grid; gap:20px; }}
  .eyebrow {{ font-size:12px; text-transform:uppercase; letter-spacing:.08em; color:var(--muted); }}
  h1 {{ font-size:27px; font-weight:700; margin:4px 0 2px; text-wrap:balance; }}
  header p {{ color:var(--ink-2); max-width:70ch; margin:6px 0 0; }}
  .badge {{ display:inline-flex; align-items:center; gap:6px; font-size:12.5px; font-weight:700;
    color:var(--good-text); border:1.5px solid currentColor; border-radius:999px; padding:3px 12px;
    vertical-align:4px; margin-left:10px; }}
  .tiles {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(165px,1fr)); gap:12px; }}
  .tile {{ background:var(--surface); border:1px solid var(--ring); border-radius:10px; padding:14px 16px; }}
  .tile .v {{ font-size:26px; font-weight:700; }} .tile .v small {{ font-size:14px; font-weight:600; color:var(--ink-2); }}
  .tile .l {{ font-size:12.5px; color:var(--ink-2); margin-top:2px; }}
  .card {{ background:var(--surface); border:1px solid var(--ring); border-radius:10px; padding:18px 20px; }}
  .card h2 {{ font-size:15px; font-weight:650; margin:0 0 2px; }}
  .card .sub {{ font-size:12.5px; color:var(--muted); margin:0 0 12px; }}
  .grid2 {{ display:grid; grid-template-columns:1fr; gap:20px; }}
  @media (min-width:880px) {{ .grid2 {{ grid-template-columns:1fr 1fr; }} }}
  svg {{ display:block; width:100%; height:auto; }}
  svg text {{ font:11.5px system-ui,sans-serif; fill:var(--ink-2); }}
  svg .val {{ fill:var(--ink); font-weight:600; font-variant-numeric:tabular-nums; }}
  svg .axisline {{ stroke:var(--axis); stroke-width:1; }}
  .shot {{ border:1px solid var(--ring); border-radius:8px; max-width:100%; display:block; }}
  table {{ width:100%; border-collapse:collapse; font-size:13.5px; }}
  th {{ text-align:left; font-size:11.5px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted);
    font-weight:600; padding:6px 10px; border-bottom:1px solid var(--axis); }}
  td {{ padding:7px 10px; border-bottom:1px solid var(--grid); vertical-align:top; }}
  .win {{ color:var(--good-text); font-weight:650; }}
  ul.value {{ margin:0; padding-left:1.1em; display:grid; gap:8px; color:var(--ink-2); }}
  ul.value strong {{ color:var(--ink); }}
  ol.gates {{ margin:0; padding:0; list-style:none; display:grid; gap:10px; }}
  ol.gates li {{ display:grid; grid-template-columns:26px 1fr; gap:10px; align-items:start;
    border-top:1px solid var(--grid); padding-top:10px; font-size:13.5px; color:var(--ink-2); }}
  ol.gates li:first-child {{ border-top:0; padding-top:0; }}
  ol.gates .g {{ color:var(--good-text); font-weight:700; }} ol.gates code {{ font-size:12px; color:var(--muted); }}
  ul.steps {{ margin:0; padding:0; list-style:none; display:grid; gap:9px; }}
  ul.steps li {{ display:grid; grid-template-columns:24px 1fr auto; gap:10px; align-items:baseline;
    font-size:14px; border-top:1px solid var(--grid); padding-top:9px; }}
  ul.steps li:first-child {{ border-top:0; padding-top:0; }}
  ul.steps .box {{ width:15px; height:15px; border:1.6px solid var(--axis); border-radius:4px; margin-top:2px; }}
  ul.steps .eff {{ font-family:ui-monospace,monospace; font-size:12px; color:var(--muted); white-space:nowrap; }}
  ul.steps .owner {{ color:var(--s2); font-size:11px; font-weight:700; text-transform:uppercase; letter-spacing:.05em; }}
  .defer {{ font-size:13.5px; color:var(--ink-2); }} .defer li {{ margin-bottom:6px; }}
  footer {{ font-size:12.5px; color:var(--muted); max-width:78ch; }}
  [data-tip] {{ cursor:default; }} [data-tip]:focus-visible {{ outline:2px solid var(--s1); outline-offset:2px; }}
  #tip {{ position:fixed; z-index:10; pointer-events:none; background:var(--ink); color:var(--plane);
    font-size:12.5px; line-height:1.35; padding:7px 10px; border-radius:7px; max-width:280px;
    opacity:0; transition:opacity .12s; }}
  @media (prefers-reduced-motion: reduce) {{ #tip {{ transition:none; }} }}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="eyebrow">Rapport de migration · {esc(r["app"])} → {esc(r["target"])} · {esc(r["date"])}</div>
    <h1>{esc(r["headline"])}<span class="badge">✓ {esc(r["badge"])}</span></h1>
    <p>{r["summary"]}</p>
  </header>
  <div class="tiles">{kpis}</div>
  <div class="card"><h2>Valeur business</h2>
    <p class="sub">Ce que cette migration change concrètement.</p><ul class="value">{business}</ul></div>
  <div class="grid2">
    {shot}
    <div class="card"><h2>Couverture du cœur porté</h2>
      <p class="sub">Lignes couvertes par les tests (cobertura, mesuré — jamais déclaré).</p>{cov_svg}</div>
  </div>
  <div class="grid2">
    <div class="card"><h2>Avant / après</h2><div style="overflow-x:auto"><table>
      <thead><tr><th></th><th>Avant</th><th>Après</th></tr></thead><tbody>{rows_ba}</tbody></table></div></div>
    <div class="card"><h2>Le code : porté, écrit, testé</h2>
      <p class="sub">Lignes de code par corps.</p>{code_svg}</div>
  </div>
  <div class="card"><h2>Portes franchies</h2>
    <p class="sub">Une porte = un commit vert sur la branche <code>{esc(r["branch"])}</code>.</p>
    <ol class="gates">{gates}</ol></div>
  {timeline}
  <div class="card"><h2>Prochaines étapes</h2>
    <p class="sub">Chemin critique vers la production, dans l'ordre.</p><ul class="steps">{steps}</ul></div>
  <div class="card"><h2>Suivis différés</h2><ul class="defer">{deferred}</ul></div>
  {lessons}
  <footer><p><strong>Méthode.</strong> {esc(r["method"])}</p></footer>
</div>
<div id="tip" role="status" aria-hidden="true"></div>
<script>
  const tip = document.getElementById('tip');
  const show = (el, x, y) => {{
    tip.textContent = el.getAttribute('data-tip'); tip.style.opacity = '1';
    const w = tip.offsetWidth, vw = window.innerWidth;
    tip.style.left = Math.min(Math.max(8, x + 12), vw - w - 8) + 'px'; tip.style.top = (y + 14) + 'px';
  }};
  document.querySelectorAll('[data-tip]').forEach(el => {{
    el.addEventListener('mousemove', e => show(el, e.clientX, e.clientY));
    el.addEventListener('mouseleave', () => tip.style.opacity = '0');
    el.addEventListener('focus', () => {{ const r = el.getBoundingClientRect(); show(el, r.left + r.width / 2, r.bottom); }});
    el.addEventListener('blur', () => tip.style.opacity = '0');
  }});
</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report_json")
    ap.add_argument("-o", "--output", default=None,
                    help="défaut : report.html à côté du report.json (pas dans le cwd)")
    args = ap.parse_args()
    r = json.loads(Path(args.report_json).read_text())
    # Les chemins du JSON (cobertura, capture) sont relatifs au JSON lui-même, pas au cwd —
    # et la sortie aussi : le dashboard vit à côté de son rapport.
    base = Path(args.report_json).resolve().parent
    # `cobertura` accepte un chemin ou une liste (un rapport par projet de test sous MTP).
    # Les report.json déjà écrits portent une chaîne : elle reste valide, normalisée ici.
    cobertura = r["coverage"]["cobertura"]
    if isinstance(cobertura, str):
        cobertura = [cobertura]
    r["coverage"]["cobertura"] = [
        p if Path(p).is_absolute() else str(base / p) for p in cobertura]
    if r.get("screenshot") and not Path(r["screenshot"]["path"]).is_absolute():
        r["screenshot"]["path"] = str(base / r["screenshot"]["path"])
    output = Path(args.output) if args.output else base / "report.html"
    output.write_text(render(r))
    print(f"OK {output}", file=sys.stderr)


if __name__ == "__main__":
    main()
