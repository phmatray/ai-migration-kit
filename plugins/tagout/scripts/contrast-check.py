#!/usr/bin/env python3
"""Contraste WCAG 2.1 — mesuré, jamais estimé à l'œil.

Usage : contrast-check.py "#fg:#bg[:libellé]" …  [--min 4.5]
AA : 4,5:1 pour le texte normal · 3:1 pour le texte large (>= 24 px, ou 19 px gras)
et les composants d'interface (--min 3).
Sortie : une ligne par paire ; code retour 1 si une paire passe sous --min.
Toute palette d'UI réécrite passe ici (thèmes clair ET sombre) avant livraison —
cf. rewrite-playbook.md."""
import argparse
import sys


def lum(hexc):
    hexc = hexc.lstrip("#")
    r, g, b = (int(hexc[i:i + 2], 16) / 255 for i in (0, 2, 4))
    f = lambda c: c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)


def ratio(fg, bg):
    hi, lo = sorted((lum(fg), lum(bg)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pairs", nargs="+", help='"#fg:#bg[:libellé]"')
    ap.add_argument("--min", type=float, default=4.5, dest="minimum")
    args = ap.parse_args()
    fail = False
    for pair in args.pairs:
        parts = pair.split(":")
        fg, bg = parts[0], parts[1]
        label = parts[2] if len(parts) > 2 else f"{fg} sur {bg}"
        r = ratio(fg, bg)
        ok = r >= args.minimum
        fail |= not ok
        print(f"{'OK  ' if ok else 'FAIL'} {r:5.2f}:1  (min {args.minimum})  {label}")
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
