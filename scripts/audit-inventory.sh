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

# Le TFM dit la vérité, pas les versions de paquets — leçon vague 3 : un webservice
# netcoreapp1.0 passait pour « déjà moderne » parce que Renovate y poussait des paquets
# 10.x. Un TFM ancien avec des paquets récents = projet mort maquillé (zombie).
def tfm(text):
    m = re.findall(r'<TargetFrameworks?>([^<]+)</TargetFrameworks?>', text)
    if m:
        return m[0]
    m = re.findall(r'<TargetFrameworkVersion>([^<]+)</TargetFrameworkVersion>', text)
    return f'net-framework {m[0]}' if m else ''

LEGACY_TFM = re.compile(r'netcoreapp[12]\.|netstandard1\.|net-framework|uap|portable', re.I)

# Le test stack se lit sur les IDENTIFIANTS de paquet, pas sur les versions — c'est tout le
# problème que cette clé existe pour rendre visible : passer de xunit v2 à v3 change l'ID
# (`xunit` -> `xunit.v3`), donc `dotnet list package --outdated` ne le proposera JAMAIS. Sans
# cette clé, la phase 1 note « framework: xUnit » et la ligne majeure reste invisible.
PKG_REF = re.compile(r'<PackageReference\b([^>]*?)(?:/>|>(.*?)</PackageReference>)', re.S)
PKG_ATTR = re.compile(r'(\w+)\s*=\s*"([^"]*)"')
TEST_PKG = re.compile(r'^(xunit|nunit|mstest|microsoft\.net\.test\.sdk|microsoft\.testing\.)', re.I)


# Gestion centralisée des versions (CPM) : la PackageReference ne porte PAS de Version, elle vit
# dans un Directory.Packages.props en amont. Sans ça, `xunitMajor` sort à null et la phase 5 lit
# « non applicable » — le non-choix silencieux que ce champ existe précisément pour supprimer.
CPM_CACHE = {}


def cpm_versions(start_dir):
    """{id: version} depuis le Directory.Packages.props le plus proche, en remontant."""
    key = str(start_dir)
    if key in CPM_CACHE:
        return CPM_CACHE[key]
    versions = {}
    here = Path(start_dir).resolve()
    root = Path('.').resolve()
    while True:
        props = here / 'Directory.Packages.props'
        if props.is_file():
            t = props.read_text(encoding='utf-8', errors='ignore')
            for pid, ver in re.findall(
                    r'<PackageVersion\s+Include="([^"]+)"[^>]*?Version="([^"]*)"', t):
                versions.setdefault(pid, ver)
        if here == root or here == here.parent:
            break
        here = here.parent
    CPM_CACHE[key] = versions
    return versions


def package_refs(text, project_dir=None):
    """{id: version} pour un csproj. Version en attribut, en élément enfant, ou via CPM."""
    refs = {}
    for m in PKG_REF.finditer(text):
        attrs = dict(PKG_ATTR.findall(m.group(1)))
        pid = attrs.get('Include') or attrs.get('Update')
        if not pid:
            continue
        version = attrs.get('Version', '')
        if not version and m.group(2):
            child = re.search(r'<Version>([^<]+)</Version>', m.group(2))
            version = child.group(1) if child else ''
        refs[pid] = version
    if project_dir is not None and any(not v for v in refs.values()):
        central = cpm_versions(project_dir)
        for pid, ver in refs.items():
            if not ver and pid in central:
                refs[pid] = central[pid]
    return refs


def packages_config_refs(project_dir):
    """{id: version} depuis un packages.config voisin — le cas legacy .NET Framework.

    C'est le public PRINCIPAL du kit : sans ça `testStack` sort vide sur exactement les dépôts
    que l'item vise, pendant que `hasTests` dit true.
    """
    cfg = Path(project_dir) / 'packages.config'
    if not cfg.is_file():
        return {}
    t = cfg.read_text(encoding='utf-8', errors='ignore')
    return {pid: ver for pid, ver in
            re.findall(r'<package\s+id="([^"]+)"\s+version="([^"]*)"', t)}


def xunit_major(refs):
    """2, 3, ou None. `xunit.v3*` porte la majeure dans son ID, pas dans sa version."""
    if any(pid.lower().startswith('xunit.v3') for pid in refs):
        return 3
    for pid in ('xunit', 'xunit.core'):
        version = next((v for k, v in refs.items() if k.lower() == pid), '')
        m = re.match(r'\D*(\d+)\.', version)
        if m:
            return int(m.group(1))
    return None


def test_framework(refs):
    ids = [pid.lower() for pid in refs]
    if any(i == 'xunit' or i.startswith('xunit.') for i in ids):
        return 'xunit'
    if any(i == 'nunit' or i.startswith('nunit.') for i in ids):
        return 'nunit'
    if any(i.startswith('mstest') for i in ids):
        return 'mstest'
    return 'unknown'


test_stack = []
for p in csproj:
    refs = package_refs(proj_texts[p], p.parent)
    legacy = packages_config_refs(p.parent)
    for pid, ver in legacy.items():
        refs.setdefault(pid, ver)
    if not any(TEST_PKG.match(pid) for pid in refs):
        continue
    test_stack.append({
        'project': p.as_posix(),
        'targetFrameworks': tfm(proj_texts[p]),
        'framework': test_framework(refs),
        'xunitMajor': xunit_major(refs),
        'packageSource': 'packages.config' if legacy else 'PackageReference',
        'packages': dict(sorted(refs.items())),
    })
test_stack.sort(key=lambda x: x['project'])

# Une copie vendorisée (`wwwroot/lib/bootstrap`, déposée fichier par fichier) ne produit AUCUNE
# entrée de manifeste : Renovate ne proposera jamais de PR dessus, Dependabot n'émettra jamais
# d'alerte. La CVE n'y est pas « non corrigée », elle est INVISIBLE — sur un dépôt qui a pourtant
# l'air entretenu (CI verte, config Renovate, Dependency Dashboard silencieux).
#
# Mesuré sur 193 dépôts .NET locaux avant d'écrire ceci (issue #32) : 17 en portent, 38 répertoires,
# 1201 fichiers, et AUCUN des 38 n'est couvert par un manifeste. Ce n'est donc pas une forme rare
# dans le public du kit — c'est presque la forme par défaut. La phase 1 est le dernier endroit où
# ce constat peut encore changer un plan, d'où cette clé plutôt qu'une étape de CI qui rapporterait
# à jamais une condition que personne n'a planifié de corriger.
#
# La clé est TOUJOURS présente, vide s'il n'y a rien : un consommateur doit pouvoir distinguer
# « mesuré, aucun » de « pas mesuré ».
VENDOR_PARENTS = (('wwwroot', 'lib'), ('wwwroot', 'vendor'))
PRUNE = {'obj', 'bin', 'packages', 'node_modules', '.git', '.vs'}


def sous_vendor(parts):
    """`parts` est À OU SOUS un répertoire `wwwroot/{lib,vendor}`."""
    return any((parts[i], parts[i + 1]) in VENDOR_PARENTS for i in range(len(parts) - 1))


def prune(dirpath, dirnames):
    """Écarte le bruit connu, et les CHECKOUTS IMBRIQUÉS — sauf s'ils SONT la copie cherchée.

    Un répertoire qui porte son propre `.git` est normalement un autre projet : worktree d'agent
    sous `.claude/worktrees/`, sous-module, clone vendorisé. Mesuré sur NetImpex avant d'ajouter
    ce filtre : 8 répertoires vendorisés rapportés pour 4 réels, 120 fichiers au lieu de 60 —
    chacun compté une seconde fois dans un worktree d'agent. Un chiffre faux, pas un manquant.

    L'exception est essentielle : SOUS `wwwroot/{lib,vendor}`, un sous-module EST la copie
    vendorisée qu'on cherche, et c'est même la forme la moins surveillée de toutes — le manager
    `git-submodules` de Renovate est désactivé par défaut, et l'écosystème `gitsubmodule` de
    Dependabot doit être activé à la main. L'écarter reviendrait à rendre aveugle précisément le
    cas pour lequel cette clé existe.
    """
    base = Path(dirpath).parts
    kept = []
    for d in dirnames:
        if d in PRUNE:
            continue
        if (os.path.exists(os.path.join(dirpath, d, '.git'))
                and not sous_vendor(base + (d,))):
            continue
        kept.append(d)
    return kept


def count_files(root):
    total = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = prune(dirpath, dirnames)
        total += len(filenames)
    return total


# La couverture se résout PAR CHEMIN et PAR PORTÉE, jamais sur un vivier global de noms courts.
# Trois défauts réels que la version « un set de noms pour tout le dépôt » produisait :
#   - `destination: "wwwroot/lib/bootstrap/dist"` n'apportait que `dist` et l'id du paquet, jamais
#     `bootstrap` : le répertoire déclaré était signalé comme angle mort (faux positif) ;
#   - dans une solution multi-app, le `package.json` de appB couvrait le `wwwroot/lib/jquery` de
#     appA (faux négatif) — or le multi-app est la forme NORMALE du public visé ;
#   - un `destination` finissant par `/dist` injectait le nom `dist` et masquait n'importe quel
#     `wwwroot/lib/dist` sans rapport.
# Un manifeste ne couvre donc que ce qui vit SOUS lui, et libman se compare en chemins.
PKG_KEYS = ('dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies')
pkg_manifests = []    # (parts du répertoire du manifeste, {noms déclarés})
libman_dests = []     # parts du chemin de destination, depuis la racine du dépôt


def lire_manifestes(dirpath, filenames):
    parts = Path(dirpath).parts
    # Un manifeste SOUS un répertoire vendorisé appartient à la copie, pas au dépôt hôte :
    # `wwwroot/lib/bootstrap/package.json` décrit bootstrap, il ne le déclare pas.
    if sous_vendor(parts):
        return
    for name in filenames:
        if name not in ('package.json', 'libman.json'):
            continue
        try:
            data = json.loads((Path(dirpath) / name).read_text(encoding='utf-8', errors='ignore'))
        except (ValueError, OSError):
            continue
        if name == 'package.json':
            noms = set()
            for key in PKG_KEYS:
                for n in (data.get(key) or {}):
                    noms.add(n)
                    noms.add(n.split('/')[-1])   # @scope/pkg -> pkg, le nom que porte le dossier
            if noms:
                pkg_manifests.append((parts, noms))
        else:
            # `bower.json` reste volontairement absent : Bower est abandonné depuis 2017 et ni
            # Renovate ni Dependabot ne le lisent. Le compter comme une couverture inverserait le
            # sens de la clé, qui dit « rien ne surveille ceci », pas « rien ne le déclare ».
            for lib in (data.get('libraries') or []):
                dest = (lib.get('destination') or '').strip('/')
                if dest:
                    libman_dests.append(parts + tuple(dest.split('/')))


def couvert(cible, est_fichier):
    """`cible` (tuple de parts) est-il déclaré par un manifeste qui a autorité sur lui ?"""
    for dir_parts, noms in pkg_manifests:
        if cible[:len(dir_parts)] != dir_parts:
            continue                                  # ce manifeste ne régit pas ce chemin
        feuille = cible[-1]
        if feuille in noms:
            return True
        if est_fichier:
            # `jquery-3.4.1.min.js` / `jquery.min.js` sont couverts par un `jquery` déclaré, mais
            # le nom doit s'arrêter net : sans la frontière, `jquery` couvrirait `jqueryui.js`.
            bas = feuille.lower()
            for n in noms:
                n = n.lower()
                if bas.startswith(n) and bas[len(n):len(n) + 1] in ('.', '-', '_'):
                    return True
    for dest in libman_dests:
        # L'un est préfixe de l'autre : `destination` peut viser le répertoire de la lib, ou un
        # sous-répertoire de celui-ci (`…/bootstrap/dist`), ou un fichier précis.
        n = min(len(dest), len(cible))
        if dest[:n] == cible[:n]:
            return True
    return False


vendored_assets = []
candidats = []
for dirpath, dirnames, filenames in os.walk('.'):
    dirnames[:] = prune(dirpath, dirnames)
    lire_manifestes(dirpath, filenames)
    # Path() normalise déjà le './' de tête qu'os.walk ajoute : Path('./wwwroot/lib').parts vaut
    # ('wwwroot', 'lib'), pas ('.', 'wwwroot', 'lib'). Un [1:] « pour retirer le point » mangerait
    # donc un vrai segment — et le motif ne matcherait plus jamais.
    parts = Path(dirpath).parts
    if parts[-2:] not in VENDOR_PARENTS:
        continue
    for lib in dirnames:
        candidats.append((parts + (lib,), os.path.join(dirpath, lib), False))
    # Un fichier POSÉ À PLAT dans `wwwroot/lib/` est une vendorisation à part entière — c'est même
    # la forme archétypale du copier-coller (`jquery-3.4.1.min.js`, `htmx.min.js`). Mesuré sur le
    # parc local : 3 dépôts, 8 fichiers, contre 17 dépôts en sous-répertoires. Rare, pas nul — et
    # sans lui `[]` voudrait parfois dire « mesuré, et raté » alors que la phase 1 le lit comme
    # « mesuré, aucun ».
    for f in filenames:
        candidats.append((parts + (f,), None, True))

# Les manifestes ne sont tous connus qu'à la fin du parcours : un `package.json` peut apparaître
# après le répertoire qu'il déclare.
for cible, disque, est_fichier in candidats:
    if couvert(cible, est_fichier):
        continue
    vendored_assets.append({
        'path': '/'.join(cible),
        'files': 1 if est_fichier else count_files(disque),
        'coveredByManifest': False,
    })
vendored_assets.sort(key=lambda x: x['path'])

proj_details = []
for p in csproj:
    own = [c for c in cs if p.parent in c.parents]
    own_ui = [u for u in ui_files if p.parent in u.parents]
    l = loc(own)
    t = tfm(proj_texts[p])
    # « récent » = majeure à deux chiffres (10+) sur une VRAIE référence de paquet : les
    # majeures 8/9 existaient déjà en 2016 (Newtonsoft 9.0.1…) et ToolsVersion="12.0"
    # des vieux csproj créeraient des faux positifs.
    recent_pkgs = bool(re.search(r'PackageReference[^>]*Version="\d{2}\.', proj_texts[p])
                       or re.search(r'<Version>\d{2}\.', proj_texts[p]))
    proj_details.append({'name': p.stem, 'csFiles': len(own), 'loc': l,
                         'targetFramework': t,
                         'zombie': bool(LEGACY_TFM.search(t)) and recent_pkgs,
                         'skeleton': (len(own) <= 1 or l < 30) and not own_ui})

print(json.dumps({
    'repo': os.environ.get('REPO_NAME', Path('.').resolve().name),
    'era': era, 'erasDetected': all_eras,
    'firstCommit': os.environ.get('FIRST_COMMIT', 'unknown'),
    'lastCommit': os.environ.get('LAST_COMMIT', 'unknown'),
    'projects': sorted(p.stem for p in csproj),
    'projectDetails': sorted(proj_details, key=lambda x: -x['loc']),
    'skeletonProjects': sorted(x['name'] for x in proj_details if x['skeleton']),
    'zombieProjects': sorted(x['name'] for x in proj_details if x['zombie']),
    'xamlPages': len(pages), 'xamlControls': len(controls), 'xamlOther': len(other_xaml),
    'xamlPageNames': sorted(p.stem for p in pages),
    'csFiles': len(cs),
    'locTotal': loc(cs), 'locCodeBehind': loc(code_behind), 'locLogic': loc(logic),
    'windowsApiClusters': dict(sorted(clusters.items(), key=lambda kv: -kv[1])),
    'packages': sorted(packages), 'hasTests': has_tests,
    'testStack': test_stack,
    'vendoredAssets': vendored_assets,
}, indent=2, ensure_ascii=False))
PY
