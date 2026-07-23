#!/usr/bin/env python3
"""Agrège les suivis ouverts des migrations (lecture seule).

Sources de vérité : le `migration/report.json` de chaque repo migré (clés `next_steps`
et `deferred`) et, en option, le backlog du kit (`--backlog docs/backlog.md`).
Aucun état parallèle : cet outil lit, trie et présente ; les mises à jour se font
dans les rapports eux-mêmes (voir le skill `followups`).

Usage : followups.py <repo> [<repo>…] [--backlog <fichier.md>] [--json]

Tri : décisions propriétaire d'abord, puis tâches par effort croissant (« ~10 min »
< « ~1 h » < sans effort), avec provenance (repo) partout.
"""
import argparse
import json
import re
import sys
from pathlib import Path


def parse_effort_minutes(effort):
    """« ~10 min » → 10 ; « ~1 h » → 60 ; illisible/absent → None (classé en dernier)."""
    if not effort:
        return None
    m = re.search(r'(\d+(?:[.,]\d+)?)\s*(min|h)', effort)
    if not m:
        return None
    value = float(m.group(1).replace(',', '.'))
    return value * 60 if m.group(2) == 'h' else value


def load_repo(repo):
    path = Path(repo) / 'migration' / 'report.json'
    if not path.is_file():
        return {'repo': Path(repo).resolve().name, 'error': f'{path} introuvable', 'next_steps': [], 'deferred': []}
    r = json.loads(path.read_text())
    name = Path(repo).resolve().name
    steps = [{'repo': name, 'text': s.get('text', ''), 'effort': s.get('effort'),
              'owner': bool(s.get('owner')), 'effortMinutes': parse_effort_minutes(s.get('effort'))}
             for s in r.get('next_steps', [])]
    deferred = [{'repo': name, 'title': d.get('strong', ''), 'text': d.get('text', '')}
                for d in r.get('deferred', [])]
    return {'repo': name, 'app': r.get('app', name), 'report': str(path),
            'next_steps': steps, 'deferred': deferred}


def load_backlog(path):
    """Backlog du kit : entrées `- **Titre** : texte` avec leur déclencheur inline."""
    entries = []
    for m in re.finditer(r'^- \*\*(.+?)\*\*\s*:?\s*(.*(?:\n  .*)*)', Path(path).read_text(), re.M):
        entries.append({'title': m.group(1).strip(), 'text': ' '.join(m.group(2).split())})
    return entries


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('repos', nargs='+', help='répertoires des repos migrés')
    ap.add_argument('--backlog', help='backlog du kit (docs/backlog.md)')
    ap.add_argument('--json', action='store_true', dest='as_json')
    args = ap.parse_args()

    repos = [load_repo(r) for r in args.repos]
    errors = [r for r in repos if r.get('error')]
    steps = [s for r in repos for s in r['next_steps']]
    owner = [s for s in steps if s['owner']]
    tasks = sorted((s for s in steps if not s['owner']),
                   key=lambda s: (s['effortMinutes'] is None, s['effortMinutes'] or 0))
    deferred = [d for r in repos for d in r['deferred']]
    backlog = load_backlog(args.backlog) if args.backlog else []

    if args.as_json:
        json.dump({'ownerDecisions': owner, 'tasks': tasks, 'deferred': deferred,
                   'kitBacklog': backlog, 'errors': [r['error'] for r in errors]},
                  sys.stdout, ensure_ascii=False, indent=2)
        print()
        return 1 if errors else 0

    print(f"# Suivis ouverts — {len(owner)} décision(s) propriétaire · "
          f"{len(tasks)} tâche(s) · {len(deferred)} différé(s) assumé(s)\n")
    for e in errors:
        print(f"⚠ {e['error']}")

    if owner:
        print("## Décisions propriétaire — n'attendent que vous\n")
        print("| Repo | Décision | Effort |")
        print("|---|---|---|")
        for s in owner:
            print(f"| {s['repo']} | {s['text']} | {s['effort'] or '—'} |")
        print()

    if tasks:
        print("## Tâches prêtes — par effort croissant\n")
        print("| Repo | Tâche | Effort |")
        print("|---|---|---|")
        for s in tasks:
            print(f"| {s['repo']} | {s['text']} | {s['effort'] or '—'} |")
        print()

    if backlog:
        print("## Backlog du kit — dettes à déclencheur (YAGNI)\n")
        for entry in backlog:
            print(f"- **{entry['title']}** : {entry['text']}")
        print()

    if deferred:
        print("## Différés assumés — pour mémoire, aucune action attendue\n")
        for d in deferred:
            print(f"- `{d['repo']}` — **{d['title']}** : {d['text']}")
        print()

    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
