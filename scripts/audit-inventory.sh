#!/usr/bin/env bash
# audit-inventory.sh <repo-dir>
# Read-only structural inventory of a .NET repo, as JSON on stdout.
# Every number in an ai-migration-kit audit report must come from here.
set -euo pipefail

REPO="${1:?usage: audit-inventory.sh <repo-dir>}"
cd "$REPO"

export REPO_NAME="$(basename "$(pwd)")"
export LAST_COMMIT="$(git log -1 --format=%cs 2>/dev/null || echo unknown)"
export FIRST_COMMIT="$(git log --reverse --format=%cs 2>/dev/null | head -1 || echo unknown)"

python3 - <<'PY'
import json, os, re, subprocess
from pathlib import Path

EXCLUDE = re.compile(r'/(obj|bin|packages|node_modules|\.git|\.vs)/')

def files(pattern):
    out = []
    for p in Path('.').rglob(pattern):
        s = '/' + p.as_posix()
        if not EXCLUDE.search(s):
            out.append(p)
    return out

def loc(paths):
    total = 0
    for p in paths:
        try:
            total += sum(1 for line in p.open(encoding='utf-8', errors='ignore') if line.strip())
        except OSError:
            pass
    return total

csproj = files('*.csproj')
proj_texts = {p: p.read_text(encoding='utf-8', errors='ignore') for p in csproj}

def detect_era():
    eras = set()
    for t in proj_texts.values():
        if 'Microsoft.NET.Sdk' in t:
            eras.add('modern-sdk')
        elif 'TargetPlatformIdentifier>UAP' in t or 'WINDOWS_UWP' in t:
            eras.add('uwp')
        elif 'WindowsPhoneApp' in t or 'WP8' in t or 'SILVERLIGHT' in t or 'Microsoft.Phone' in t:
            eras.add('windows-phone')
        elif re.search(r'TargetPlatformVersion>8\.', t) or 'AppContainerExe' in t:
            eras.add('winrt-8x')
        else:
            eras.add('netfx-classic')
    order = ['winrt-8x', 'windows-phone', 'uwp', 'netfx-classic', 'modern-sdk']
    for e in order:
        if e in eras:
            return e, sorted(eras)
    return 'unknown', sorted(eras)

era, all_eras = detect_era()

xaml = files('*.xaml')
pages, controls, other_xaml = [], [], []
for p in xaml:
    t = p.read_text(encoding='utf-8', errors='ignore')
    if re.search(r'<(Page|phone:PhoneApplicationPage|PhoneApplicationPage|Window)[\s>]', t):
        pages.append(p)
    elif re.search(r'<UserControl[\s>]', t):
        controls.append(p)
    else:
        other_xaml.append(p)

cs = [p for p in files('*.cs')
      if not re.search(r'(\.g\.|\.g\.i\.|Designer|AssemblyInfo|TemporaryGeneratedFile)', p.name)]
code_behind = [p for p in cs if p.name.endswith('.xaml.cs')]
logic = [p for p in cs if not p.name.endswith('.xaml.cs')]

API_CLUSTERS = ['Windows.Storage', 'Windows.UI', 'Windows.ApplicationModel', 'Windows.Networking',
                'Windows.Media', 'Windows.Devices', 'Windows.Security', 'Windows.System',
                'Microsoft.Phone', 'System.Windows', 'System.Net.Http']
clusters = {}
for p in cs:
    t = p.read_text(encoding='utf-8', errors='ignore')
    for c in API_CLUSTERS:
        n = len(re.findall(r'\b' + re.escape(c) + r'\b', t))
        if n:
            clusters[c] = clusters.get(c, 0) + n

packages = set()
for p in files('packages.config'):
    packages |= set(re.findall(r'id="([^"]+)"', p.read_text(encoding='utf-8', errors='ignore')))
for p in files('project.json'):
    try:
        packages |= set(json.loads(p.read_text(encoding='utf-8', errors='ignore')).get('dependencies', {}))
    except ValueError:
        pass
for t in proj_texts.values():
    packages |= set(re.findall(r'PackageReference Include="([^"]+)"', t))

has_tests = any(re.search(r'\[(Fact|Test|TestMethod)\]', p.read_text(encoding='utf-8', errors='ignore'))
                for p in cs) or any('Test' in p.stem for p in csproj)

# Un « projet-squelette » (échafaudage vide : un Class1.cs, presque zéro LOC) ne vaut rien
# dans un chiffrage — leçon vague 2 : 5 projets « architecture en couches » vides avaient
# gonflé la part de logique portable de l'audit. Un projet dont l'UI vit en .xaml/.razor
# n'est pas un squelette même avec peu de .cs.
ui_files = files('*.razor') + xaml
proj_details = []
for p in csproj:
    own = [c for c in cs if p.parent in c.parents]
    own_ui = [u for u in ui_files if p.parent in u.parents]
    l = loc(own)
    proj_details.append({'name': p.stem, 'csFiles': len(own), 'loc': l,
                         'skeleton': (len(own) <= 1 or l < 30) and not own_ui})

print(json.dumps({
    'repo': os.environ.get('REPO_NAME', Path('.').resolve().name),
    'era': era, 'erasDetected': all_eras,
    'firstCommit': os.environ.get('FIRST_COMMIT', 'unknown'),
    'lastCommit': os.environ.get('LAST_COMMIT', 'unknown'),
    'projects': sorted(p.stem for p in csproj),
    'projectDetails': sorted(proj_details, key=lambda x: -x['loc']),
    'skeletonProjects': sorted(x['name'] for x in proj_details if x['skeleton']),
    'xamlPages': len(pages), 'xamlControls': len(controls), 'xamlOther': len(other_xaml),
    'xamlPageNames': sorted(p.stem for p in pages),
    'csFiles': len(cs),
    'locTotal': loc(cs), 'locCodeBehind': loc(code_behind), 'locLogic': loc(logic),
    'windowsApiClusters': dict(sorted(clusters.items(), key=lambda kv: -kv[1])),
    'packages': sorted(packages), 'hasTests': has_tests,
}, indent=2, ensure_ascii=False))
PY
