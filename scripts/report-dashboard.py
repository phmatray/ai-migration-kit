#!/usr/bin/env python3
"""Génère le dashboard exécutif d'une migration (migration/report.html).

Usage : report-dashboard.py <report.json> [-o report.html]

Entrées (report.json) : contenu du rapport (KPIs, valeur business, avant/après,
portes, next steps…). La couverture est lue depuis un ou plusieurs cobertura.xml
— jamais déclarée à la main. `coverage.cobertura` accepte un fichier, une liste de
fichiers, un RÉPERTOIRE, ou un motif glob ; sous Microsoft Testing Platform chaque
projet de test écrit son propre rapport sous un nom généré, donc **pointer sur le
répertoire `coverage/`** est la forme durable — un chemin littéral serait périmé au
run suivant. Les rapports sont agrégés (cf. parse_cobertura), jamais concaténés.
La capture est embarquée en data URI.
Sortie : document HTML autonome (double-cliquable, envoyable), thème clair/sombre,
palette validée (cf. dashboard d'audit du kit).
"""
import argparse
import base64
import glob
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


def _branch_rate(root):
    """Le `branch-rate` racine d'un rapport — seulement s'il ressemble à un taux.

    Un `try/except ValueError` seul ne suffit pas : `nan` et `inf` se parsent très bien et font
    ensuite exploser `round()` au moment du rendu, loin d'ici ; un producteur qui écrit le taux en
    pourcent (`60`) rendrait « 6000 % branches ». Un attribut qu'on ne sait pas interpréter n'est
    pas une mesure — on rend None, et l'appelant affichera « n/d ».
    """
    raw = root.get("branch-rate")
    if raw is None:
        return None
    try:
        rate = float(raw)
    except ValueError:
        return None
    # Faux pour nan et inf, donc les deux tombent ici sans test dédié.
    return rate if 0.0 <= rate <= 1.0 else None


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

    ⚠ Une seule exception, introduite par #50 : le `branch-rate` de la racine est lu, en REPLI,
    quand aucune ligne du périmètre ne porte de `condition-coverage`. Il n'est admis que pour un
    rapport UNIQUE et NON FILTRÉ — précisément parce que le raisonnement ci-dessus s'y applique
    aussi : c'est un taux global, il ignore `exclude`/`include`, et le moyenner sur plusieurs
    rapports n'aurait pas de sens. Hors de ce cas, la fonction rend None plutôt qu'un chiffre
    qu'elle ne saurait pas défendre.

    Conséquence sur le contrat : `line_pct` et `branch_pct` sont Optional[int]. None veut dire
    « pas mesuré » — le rendu l'affiche `n/d`, jamais 0 %.
    """
    if isinstance(paths, (str, Path)):
        paths = [paths]
    # Clé = nom COMPLET de la classe : deux namespaces peuvent porter le même nom court, et
    # les fusionner mélangerait deux classes distinctes. L'ordre d'insertion est l'ordre du
    # document, donc les ex æquo gardent l'ordre d'origine après le tri (stable).
    merged = {}
    # `branch-rate` de la racine, gardé en repli. Tous les producteurs de cobertura n'écrivent pas
    # de `condition-coverage` par ligne ; ceux de la chaîne VSTest/coverlet expriment souvent leurs
    # branches ici seulement. Ne lire que les lignes rendait alors « 0 % branches » sur une
    # application bien couverte — une absence de donnée affichée comme une mesure (#50).
    root_branch_rates = []
    reports_with_conditions = 0
    for path in paths:
        root = ET.parse(path).getroot()
        rate = _branch_rate(root)
        if rate is not None:
            root_branch_rates.append(rate)
        saw_conditions = False
        for cls in root.iter("class"):
            name = cls.get("name")
            if "<" in name or "/" in name:
                continue
            if any(name.startswith(p) for p in excluded_prefixes):
                continue
            if included_names and name.split(".")[-1] not in included_names:
                continue
            by_line = merged.setdefault(name, {})
            # Identité d'une ligne = (fichier, numéro), jamais le seul numéro : une classe
            # PARTIELLE est émise une fois par fichier source (`Foo.cs` + `Foo.Designer.cs`,
            # omniprésent dans le legacy WinForms/WebForms que ce kit migre), et les deux
            # commencent à la ligne 1. Fusionner sur le numéro seul additionnerait les hits de
            # deux lignes sans rapport et perdrait la moitié du dénominateur.
            for l in cls.findall(".//line"):
                slot = by_line.setdefault((cls.get("filename"), l.get("number")), [0, 0, 0])
                covered, total = _conditions(l)
                if total:
                    saw_conditions = True
                slot[0] += int(l.get("hits"))
                # Le maximum, pas la somme : deux rapports qui couvrent LA MÊME branche
                # rendraient 2/2 sur une ligne qui n'en a qu'une de couverte. Le maximum
                # sous-estime quand ils en couvrent deux différentes — on préfère l'erreur
                # qui ne surestime jamais une couverture.
                slot[1], slot[2] = max(slot[1], covered), max(slot[2], total)
        if saw_conditions:
            reports_with_conditions += 1
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
    # Un périmètre vide n'est pas une couverture de 0 % : c'est une absence de mesure. Le cas se
    # produit pour de bon — un `include` portant un nom de classe devenu périmé après un renommage
    # filtre TOUT, et la page publiait alors « Global : 0 % lignes » sous une tuile qui gardait le
    # chiffre écrit à la main. Deux chiffres contradictoires, à nouveau (#50).
    line_pct = round(100 * lines_covered / lines_total) if lines_total else None

    # Trois états, jamais deux — et le repli est délibérément ÉTROIT.
    #
    #  1. Les `condition-coverage` par ligne, quand TOUS les rapports en portent : c'est la seule
    #     forme unionnable, et la seule qui respecte `exclude`/`include`, puisqu'elle est lue
    #     classe par classe. Si seuls certains rapports en portent, le total ne décrirait qu'un
    #     sous-ensemble tout en s'affichant « Global » — donc None plutôt qu'un chiffre partiel.
    #  2. Sinon le `branch-rate` racine, mais UNIQUEMENT pour un rapport unique et sans filtre.
    #     C'est un attribut global : il ignore `exclude`/`include` (il rendait « 100 % lignes ·
    #     20 % branches » alors que le 20 % venait surtout du projet exclu), et sur plusieurs
    #     rapports une moyenne non pondérée n'a pas de sens — sous MTP chaque rapport déclare le
    #     produit entier, donc 0,9 et 0,1 rendaient 50 % quelle que soit la taille des suites.
    #  3. Sinon None, que le rendu affiche « n/d ». Ne rien savoir n'est pas mesurer zéro.
    scoped = bool(excluded_prefixes or included_names)
    if br_total and reports_with_conditions == len(paths):
        branch_pct = round(100 * br_covered / br_total)
    elif not br_total and len(paths) == 1 and not scoped and root_branch_rates:
        branch_pct = round(100 * root_branch_rates[0])
    else:
        branch_pct = None

    return {
        "classes": classes,
        "line_pct": line_pct,
        "branch_pct": branch_pct,
    }


def resolution_hint(item, base):
    """La clause qui NOMME la base contre laquelle un chemin relatif vient d'être résolu.

    Tous les chemins d'un `report.json` (cobertura, capture) sont relatifs AU RAPPORT, jamais au
    cwd ni à la racine du repo. Les diagnostics, eux, affichent le chemin RÉSOLU — donc un chemin
    que l'auteur n'a jamais tapé, sans un mot sur d'où il sort. C'est exactement ce qui a produit
    #49 : `"coverage"` écrit dans `migration/report.json` désigne `migration/coverage`, et
    « introuvable : …/migration/coverage » ne laissait aucune prise pour comprendre pourquoi.
    Corriger la référence retirait la valeur fausse du jour ; nommer la base ferme la classe
    entière — tout champ relatif, y compris ceux ajoutés plus tard (#102).

    Un chemin ABSOLU n'a été résolu contre rien : la clause serait un mensonge, donc elle est vide.
    """
    if Path(item).is_absolute():
        return ""
    return f" (chemin relatif résolu depuis {base}, le répertoire du report.json)"


def resolve_cobertura(entry, base):
    """Résout le champ `coverage.cobertura` en liste de fichiers, relatifs au report.json.

    Quatre formes, toutes acceptées — la première pour les rapports déjà écrits, les trois
    autres parce que sous MTP c'est le collecteur qui NOMME les fichiers, avec un GUID neuf à
    chaque run : un chemin littéral écrit dans un report.json versionné serait mort au run
    suivant. Le répertoire est donc la forme à privilégier.

      "coverage/coverage.cobertura.xml"        un fichier
      ["a.cobertura.xml", "b.cobertura.xml"]   plusieurs fichiers
      "coverage"                               un répertoire → tous ses *.cobertura.xml
      "coverage/*.cobertura.xml"               un motif glob
    """
    entries = [entry] if isinstance(entry, str) else list(entry)
    files = []
    for item in entries:
        path = Path(item) if Path(item).is_absolute() else base / item
        hint = resolution_hint(item, base)
        if path.is_dir():
            found = sorted(path.rglob("*.cobertura.xml"))
            if not found:
                raise SystemExit(f"aucun *.cobertura.xml dans le répertoire {path}{hint}")
            files.extend(found)
        elif any(c in str(item) for c in "*?["):
            found = sorted(Path(p) for p in glob.glob(str(path), recursive=True))
            if not found:
                raise SystemExit(f"le motif {path} ne correspond à aucun fichier{hint}")
            files.extend(found)
        else:
            # Nommer le fichier manquant : un FileNotFoundError brut d'ET.parse ne dit pas
            # lequel des N rapports a disparu, et sous MTP ils changent de nom à chaque run.
            if not path.is_file():
                # …et ne pas appeler « rapport » ce qui a été écrit comme un RÉPERTOIRE. La
                # branche `is_dir()` ci-dessus ne se prend que si le dossier EXISTE ; un dossier
                # absent retombe ici, et « rapport de couverture introuvable » envoyait alors
                # chercher un fichier là où l'auteur avait désigné un dossier (#102). Le
                # discriminant est le suffixe `.xml` : c'est la seule forme fichier que les quatre
                # formes documentées emploient, tout le reste désigne un répertoire.
                kind = ("rapport de couverture" if path.suffix.lower() == ".xml"
                        else "répertoire de couverture")
                raise SystemExit(f"{kind} introuvable : {path}{hint}")
            files.append(path)
    if not files:
        raise SystemExit("coverage.cobertura ne désigne aucun rapport")
    # Dédoublonne : un répertoire et un fichier qu'il contient peuvent être listés tous les
    # deux, et lire deux fois le même rapport gonflerait les hits sans changer le total.
    seen, unique = set(), []
    for f in files:
        key = f.resolve()
        if key not in seen:
            seen.add(key)
            unique.append(str(f))
    return unique


def data_uri(path):
    ext = Path(path).suffix.lstrip(".").lower()
    mime = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "svg": "image/svg+xml"}[ext]
    return f"data:{mime};base64," + base64.b64encode(Path(path).read_bytes()).decode()


def hbar_chart(rows, aria, note, multi_hue=False):
    """rows: [{label, value(0..max), display, tip, hue?}] — barres horizontales SVG."""
    gutter, right_pad, width = 190, 70, 660
    # Aucune barre, ou toutes à zéro : le dashboard doit le DIRE, pas planter sur un
    # `max()` vide ou une division par zéro. C'est un état atteignable — un jeu de rapports
    # entièrement exclu par `coverage.exclude`, ou une collecte qui n'a rien instrumenté.
    if not rows:
        return (f'<svg viewBox="0 0 {width} 40" role="img" aria-label="{esc(aria)}">'
                f'<text x="0" y="24" fill="var(--muted)">{esc(note or "Aucune donnée")}</text></svg>')
    largest = max(r["value"] for r in rows)
    scale = (width - gutter - right_pad) / largest if largest else 0
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


# Une tuile déclare la grandeur qu'elle rend : `"source": "line_pct"` ou `"branch_pct"`. À défaut —
# et c'est le cas de tous les `report.json` déjà écrits, qui ne portent aucun marqueur — on retombe
# sur le libellé : une tuile en `%` qui parle de couverture rend les LIGNES, sauf si elle parle de
# branches, auquel cas elle rend les branches.
#
# Cette distinction n'est pas cosmétique : sans elle, une tuile « Couverture de branches » recevait
# le taux de LIGNES. Mesuré — la page affichait alors 70 % dans la tuile au-dessus d'un
# « Global : 70 % lignes · 67 % branches », soit exactement les deux chiffres contradictoires que ce
# mécanisme existe pour supprimer, reproduits par le correctif lui-même.
COVERAGE_KPI = re.compile(r"couvertur", re.I)
BRANCH_KPI = re.compile(r"branch", re.I)
KPI_SOURCES = ("line_pct", "branch_pct")


def kpi_source(k):
    """La grandeur mesurée qu'une tuile doit rendre, ou None si elle n'en rend aucune."""
    declared = k.get("source")
    if declared in KPI_SOURCES:
        return declared
    if k.get("unit") != "%":
        return None
    label = k.get("label", "")
    if not COVERAGE_KPI.search(label):
        return None
    return "branch_pct" if BRANCH_KPI.search(label) else "line_pct"


def kpi_value(k, cov):
    """La valeur à rendre pour une tuile : la MESURE quand il y en a une (#50).

    Le tableau de bord affichait deux chiffres de couverture sur la même page — la tuile recopiée
    depuis `report.json` (un nombre tapé par un humain) au-dessus d'une légende recalculée depuis
    les coberturas. La fixture du kit publiait ainsi 70 % au-dessus de « Global : 75 % », sur
    l'artefact même que le kit donne en exemple de « couverture mesurée, jamais estimée ». Deux
    rendus de la même quantité rendent la promesse invérifiable depuis la page : le lecteur ne peut
    pas savoir lequel est la mesure.

    Là où une mesure existe, elle gagne. Là où il n'y en a pas — grandeur absente du rapport, ou
    périmètre filtré jusqu'à ne plus rien contenir — la valeur écrite est rendue telle quelle,
    faute de mieux, et la légende dit `n/d` de son côté plutôt que d'inventer un zéro.
    """
    source = kpi_source(k)
    if source is not None and cov.get(source) is not None:
        return str(cov[source])
    return k["v"]


def render(r):
    cov = parse_cobertura(r["coverage"]["cobertura"], r["coverage"].get("exclude", []),
                          r["coverage"].get("include"))
    kpis = "".join(
        f'<div class="tile"><div class="v">{esc(kpi_value(k, cov))}'
        + (f'<small>{esc(k["unit"])}</small>' if k.get("unit") else "")
        + f'</div><div class="l">{esc(k["label"])}</div></div>'
        for k in r["kpis"])
    business = "".join(
        f'<li><strong>{esc(b["strong"])}</strong> {esc(b["text"])}</li>' for b in r["business"])
    cov_rows = [{"label": c["name"], "value": c["pct"], "display": f'{c["pct"]} %',
                 "tip": f'{c["name"]} : {c["covered"]}/{c["total"]} lignes couvertes'}
                for c in cov["classes"]]
    # « n/d » et jamais « 0 % » quand la grandeur n'a pas été mesurée : un zéro est un chiffre, et
    # sur cette page un chiffre se lit comme une mesure (#50). Vaut pour les deux axes — un
    # périmètre filtré jusqu'au vide affichait « 0 % lignes » avec le même aplomb.
    lignes = (f'{cov["line_pct"]} % lignes' if cov["line_pct"] is not None else 'lignes n/d')
    branches = (f'{cov["branch_pct"]} % branches' if cov["branch_pct"] is not None
                else 'branches n/d')
    cov_note = (f'Global : {lignes} · {branches}'
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
    r["coverage"]["cobertura"] = resolve_cobertura(r["coverage"]["cobertura"], base)
    if r.get("screenshot"):
        # Même base, donc même diagnostic. Une capture absente remontait un FileNotFoundError brut
        # depuis `data_uri` — une trace Python à la fin d'un long pipeline, sur l'artefact censé
        # prouver le travail, et sans un mot sur la base contre laquelle le chemin a été résolu.
        # C'est le même défaut que la couverture, en pire : là il n'y avait même pas de phrase (#102).
        item = r["screenshot"]["path"]
        path = Path(item) if Path(item).is_absolute() else base / item
        if not path.is_file():
            raise SystemExit(f"capture introuvable : {path}{resolution_hint(item, base)}")
        r["screenshot"]["path"] = str(path)
    output = Path(args.output) if args.output else base / "report.html"
    output.write_text(render(r))
    print(f"OK {output}", file=sys.stderr)


if __name__ == "__main__":
    main()
