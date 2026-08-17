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
import fnmatch, json, os, re, subprocess
from pathlib import Path

# ── LA règle de parcours, unique ────────────────────────────────────────────────────────────────
# Il y en avait deux : une regex `EXCLUDE` pour `files()` (donc csFiles, locTotal, testStack,
# projectDetails…) et un `prune()` pour le seul scan vendorisé, ajouté par #64. Elles avaient
# divergé, et tout ce que ce script émet est lu comme une mesure — la phase 1 recopie `testStack[]`
# et `vendoredAssets[]` dans l'évaluation. Deux règles = un document incohérent avec lui-même, sans
# le moindre symptôme. Mesuré avant la correction (#65) :
#   - `ai-migration-kit` annonçait testStack = 6 pour UN seul projet de test : les cinq autres
#     étaient des copies de samples/LegacyShop dans ses propres worktrees d'agent ;
#   - Koine 1825 csFiles, NetImpex 1116, repo-audit 348 — tous gonflés par des copies ;
#   - `openjam-monorepo` annonçait csFiles = 0, locTotal = 0, testStack = 0. Pas « petit » :
#     INVISIBLE, parce que tous ses projets vivent sous `packages/`. Des zéros, pas une erreur.
PRUNE = {'obj', 'bin', 'node_modules', '.git', '.vs'}
VENDOR_PARENTS = (('wwwroot', 'lib'), ('wwwroot', 'vendor'))

# Un répertoire écarté par une décision — pas par la liste de bruit évidente — doit être NOMMÉ, pas
# disparaître. C'est une leçon déjà payée ailleurs dans le portefeuille : une sonde qui faisait
# `continue` en silence comptait 148 dépôts là où 210 étaient éligibles, et le chiffre manquant
# n'existait dans aucun relevé. Ici le risque est le même dans les deux sens — un sous-module peut
# porter du code de première main, un `packages/` peut porter les applications — donc la clé
# `excludedFromWalk` rend le choix visible au lecteur de la phase 1 au lieu de le lui cacher
# derrière un nombre plus petit.
ECARTES = {}


def sous_vendor(parts):
    """`parts` est À OU SOUS un répertoire `wwwroot/{lib,vendor}`."""
    return any((parts[i], parts[i + 1]) in VENDOR_PARENTS for i in range(len(parts) - 1))


ID_VERSION = re.compile(r'\.\d+(\.\d+)*$')
PROJET_EXT = ('.csproj', '.fsproj', '.vbproj')

# La sonde ci-dessous s'arrête aux PETITS-ENFANTS de l'enfant de `packages/` — un cran, pas une
# récursion. Le chiffre n'est pas un réglage de coût, c'est le DISCRIMINANT (#107) :
#
#   - un paquet NuGet extrait n'a jamais de projet à cette profondeur. Sa disposition interpose
#     toujours un répertoire de framework — `lib/<tfm>/`, `contentFiles/<lang>/<tfm>/`,
#     `build/<tfm>/` — donc ce que la restauration écrit tombe au moins un cran plus bas ;
#   - un paquet de première main, lui, range son projet exactement là : `<Pkg>/src/X.csproj`,
#     `<Pkg>/lib/X.csproj`, `<Pkg>/<version>/X.csproj`.
#
# Descendre plus bas ne gagnerait donc rien et coûterait le cas (b) de tests/audit-inventory :
# `packages/somelib/lib/net45/Third.csproj`, un `packages/` committé dont le code tiers doit rester
# dehors, deviendrait « source ». Remonter à 1 ne fait que retrouver le bug : c'est la profondeur
# que les marques source lisaient déjà, pendant que les signaux de restauration en lisaient deux.
PROFONDEUR_SONDE = 2


def _lecture(chemin):
    """(noms des FICHIERS, chemins des sous-répertoires retenus) — un seul `scandir`.

    Les deux moitiés sortent du même passage parce que la sonde ci-dessous a besoin des deux à
    chaque niveau : les fichiers pour décider, les répertoires pour descendre. `PRUNE` est appliqué
    ici aussi — sonder `node_modules/` ou `obj/` coûterait cher pour ne rien apprendre.
    """
    fichiers, dossiers = set(), []
    try:
        with os.scandir(chemin) as sous:
            for e in sous:
                if e.is_dir(follow_symlinks=False):
                    if e.name not in PRUNE:
                        dossiers.append(e.path)
                else:
                    fichiers.add(e.name)
    except OSError:
        pass
    return fichiers, dossiers


def projet_sous_l_enfant(chemin):
    """Un projet (ou un `package.json`) dans un SOUS-RÉPERTOIRE immédiat de cet enfant ?

    `paquet_restaure()` cherchait les marques « source » sur les seuls enfants immédiats du
    répertoire, alors qu'il appliquait ses signaux de restauration sur DEUX niveaux (`lib/`,
    `content/`, un petit-enfant en forme de version). Un paquet de première main dont le projet vit
    un cran plus bas perdait donc sur les deux tableaux — mesuré sur `main` avant #107 :

        packages/MyLib/lib/MyLib.csproj + Svc.cs -> projects=['App'], csFiles=1 (2 attendus)
        packages/api/1.0/Api.csproj              -> projects=['App']

    …avec le répertoire NOMMÉ dans `excludedFromWalk` dans les deux cas, ce qui borne la gravité
    (#65 a ajouté cette clé pour ça) mais ne rend ni les fichiers ni les lignes comptés.

    La sonde est bornée à `PROFONDEUR_SONDE` niveaux — voir le commentaire de cette constante : la
    borne est ce qui distingue « projet de première main sous `lib/` » de « code tiers sous
    `lib/<tfm>/` », pas seulement une limite de coût.
    """
    niveau = _lecture(chemin)[1]          # profondeur 2 : l'appelant a déjà lu la profondeur 1
    for _ in range(PROFONDEUR_SONDE - 1):
        if not niveau:
            return False
        suivant = []
        for d in niveau:
            fichiers, dossiers = _lecture(d)
            if 'package.json' in fichiers or any(n.endswith(PROJET_EXT) for n in fichiers):
                return True
            suivant.extend(dossiers)
        niveau = suivant
    return False


def paquet_restaure(nom, chemin):
    """Cet enfant de `packages/` est-il un paquet NuGet restauré plutôt qu'un projet du dépôt ?

    `packages` était écarté inconditionnellement : juste pour le public legacy, où c'est le dossier
    de restauration, et catastrophique pour un monorepo qui y range ses applications — mesuré,
    openjam-monorepo annonçait csFiles = 0, INVISIBLE. La détection par DÉCLARATION (`workspaces`)
    était le plan de #65, morte à la mesure : ZÉRO dépôt local n'en déclare, et openjam-monorepo
    n'a aucun package.json racine.

    Le correctif suivant testait le répertoire ENTIER sur `.nupkg` / `repositories.config`. La revue
    l'a cassé à raison : le .gitignore standard de Visual Studio exclut `*.nupkg`,
    `repositories.config` est un artefact NuGet 2.x que la restauration moderne n'écrit plus, et la
    disposition « global packages » place le .nupkg trois niveaux plus bas. Un `packages/` committé
    sans .nupkg était donc parcouru, et du code tiers comptait pour celui du dépôt (csFiles 1 → 11).

    Le verdict se prend donc PAR ENFANT, et c'est un gain double. Plus juste : un monorepo qui
    vendorise aussi quelques paquets garde ses applications et perd seulement les paquets. Et
    testable : avec un verdict global, dès qu'aucun enfant n'est source la réponse est « écarter »
    quelle que soit la raison — aucun test ne pouvait donc distinguer les signaux, et la
    mutation-test le montrait (4 mutants sur 6 survivaient). Par enfant, chaque signal décide seul
    du sort d'un répertoire observable.

    Signaux mesurés sur les 8 `packages/` réels du parc (7 restauration, 1 source) :

        signal                          restauration   source
        enfants `<Id>.<Version>`             3 à 28        0
        enfants portant lib/ ou content/     3 à 20        0
        enfants portant un projet ou src/         0       11
        `.nuspec`                                 0        0   <- inutile, absent partout
        le dépôt a un packages.config        1 à 3         1   <- ne discrimine pas

    Ces chiffres viennent d'une sonde jetable, ce qui les rendrait invérifiables si elle n'était
    nulle part : elle est publiée en entier sur l'issue #65, avec la commande qui la rejoue. Ce
    qui garde la règle honnête au quotidien n'est pas ce tableau mais `tests/audit-inventory` :
    chaque branche ci-dessous a son propre cas, et chacune est mutation-testée — on la casse, la
    suite tombe. Le tableau explique le choix ; la suite l'empêche de dériver.

    #107 a ajouté une branche à cette liste, et c'était une correction de PROFONDEUR : les marques
    « source » n'étaient lues que sur les enfants immédiats, quand les signaux de restauration en
    lisaient deux — un paquet de première main dont le projet vit un cran plus bas perdait donc sur
    les deux tableaux. `projet_sous_l_enfant()` comble l'écart, borné à `PROFONDEUR_SONDE`, et
    passe APRÈS `<Id>.<Version>` : voir son commentaire à cet endroit.
    """
    noms, dossiers = set(), set()
    try:
        with os.scandir(chemin) as sous:
            for e in sous:
                noms.add(e.name)
                if e.is_dir(follow_symlinks=False):
                    dossiers.add(e.name)
    except OSError:
        return False
    # Un projet qui s'est empaqueté lui-même (`dotnet pack -o .`) porte un `.nupkg` à côté de son
    # csproj et reste du code du dépôt : la marque « source » l'emporte, toujours. Sans cette
    # priorité, un artefact perdu rendait invisibles toutes les applications du monorepo.
    if 'package.json' in noms or 'src' in noms or any(n.endswith(PROJET_EXT) for n in noms):
        return False
    if ID_VERSION.search(nom):
        return True                       # packages/Newtonsoft.Json.13.0.1
    # …et le NOM passe AVANT la sonde en profondeur, contrairement aux marques immédiates
    # ci-dessus. L'asymétrie est mesurée, pas esthétique : un paquet NuGet extrait n'a jamais de
    # projet à sa racine, donc une marque immédiate lève l'ambiguïté à elle seule — alors qu'un
    # cran plus bas, `content/`, `contentFiles/` et `tools/` en livrent parfois un pour de vrai.
    # À cette profondeur-là, `<Id>.<Version>` — une forme qu'un paquet de première main n'a pas —
    # est le signal le plus fiable des deux, et il tranche.
    #
    # Cet ordre paie aussi le coût de la sonde : sur un `packages/` de restauration réel, dont les
    # 3 à 28 enfants portent tous ce nom, on n'y arrive jamais. Elle ne s'exécute que là où le
    # verdict était réellement douteux (#94 possède le sujet du coût de parcours).
    if projet_sous_l_enfant(chemin):
        return False                      # packages/MyLib/lib/MyLib.csproj — #107
    if 'lib' in noms or 'content' in noms:
        return True                       # la disposition extraite, même sans .nupkg committé
    if any(n.endswith('.nupkg') for n in noms):
        return True
    # Disposition « global packages » v3 : packages/<id>/<version>/… — l'enfant porte le nom du
    # paquet et la version est un cran plus bas. `dotnet restore --packages packages` produit ça.
    if dossiers and all(ID_VERSION.search(d) or d.isdigit() for d in dossiers):
        return True
    return False


def prune(dirpath, dirnames, garder_vendor=False):
    """Écarte le bruit connu, la restauration NuGet, et les CHECKOUTS IMBRIQUÉS.

    Un répertoire portant son propre `.git` est un autre projet : worktree d'agent, sous-module,
    clone vendorisé. Ses fichiers ne sont pas le code de ce dépôt. Mesuré sur NetImpex : 8
    répertoires vendorisés rapportés pour 4 réels, 120 fichiers au lieu de 60.

    `garder_vendor` porte l'unique exception, et elle est réservée au scan vendorisé : SOUS
    `wwwroot/{lib,vendor}`, un sous-module EST la copie cherchée — et la moins surveillée de
    toutes. Les autres clés n'en veulent pas : le code d'une lib vendorisée n'est pas le code du
    dépôt. Une règle, une exception nommée, plutôt que deux règles qui dérivent.
    """
    base = Path(dirpath).parts
    dans_packages = bool(base) and base[-1] == 'packages'
    kept = []
    for d in dirnames:
        if d in PRUNE:
            continue
        chemin = os.path.join(dirpath, d)
        if dans_packages and paquet_restaure(d, chemin):
            ECARTES.setdefault('/'.join(base + (d,)), 'paquet NuGet restauré')
            continue
        if os.path.exists(os.path.join(chemin, '.git')):
            if garder_vendor and sous_vendor(base + (d,)):
                kept.append(d)
                continue
            ECARTES.setdefault('/'.join(base + (d,)), 'checkout imbriqué')
            continue
        kept.append(d)
    return kept


def _tous_les_fichiers():
    out = []
    for dirpath, dirnames, filenames in os.walk('.'):
        dirnames[:] = prune(dirpath, dirnames)
        base = Path(dirpath)
        out.extend(base / f for f in filenames)
    return out


TOUS_FICHIERS = _tous_les_fichiers()


def files(pattern):
    """Les fichiers du dépôt dont le NOM matche `pattern` — mêmes chemins que l'ancien rglob."""
    return [p for p in TOUS_FICHIERS if fnmatch.fnmatch(p.name, pattern)]

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
# `VENDOR_PARENTS`, `PRUNE`, `sous_vendor()` et `prune()` vivent en tête de fichier, avec la règle
# de parcours unique : c'était précisément la duplication que #65 a supprimée. Ici on ne fait
# qu'activer l'exception `garder_vendor` — le seul endroit du script qui en veut.


def count_files(root):
    total = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = prune(dirpath, dirnames, garder_vendor=True)
        # `.git` n'est dans PRUNE qu'en tant que RÉPERTOIRE. Le pointeur d'un sous-module ou d'un
        # worktree est un FICHIER nommé `.git`, qui retombait donc dans `filenames` et ajoutait 1
        # à chaque bibliothèque vendorisée par sous-module. Un chiffre lu comme un décompte.
        total += sum(1 for f in filenames if f != '.git')
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
# Ce qu'un fichier posé à plat doit être pour compter comme une bibliothèque vendorisée.
ASSET_EXT = {'.js', '.mjs', '.cjs', '.css', '.scss', '.map', '.woff', '.woff2', '.ttf', '.eot'}
pkg_manifests = []    # (parts du répertoire, {noms déclarés}, chemin du manifeste)
libman_dests = []     # (parts de la destination, parts du répertoire, chemin du manifeste)


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
                pkg_manifests.append((parts, noms, '/'.join(parts + (name,))))
        else:
            # `bower.json` reste volontairement absent : Bower est abandonné depuis 2017 et ni
            # Renovate ni Dependabot ne le lisent. Le compter comme une couverture inverserait le
            # sens de la clé, qui dit « rien ne surveille ceci », pas « rien ne le déclare ».
            for lib in (data.get('libraries') or []):
                dest = (lib.get('destination') or '').strip('/')
                if dest:
                    libman_dests.append((parts + tuple(dest.split('/')),
                                         parts, '/'.join(parts + (name,))))


def couvert(cible, est_fichier):
    """Quel manifeste déclare `cible` ? -> son chemin, ou None.

    Renvoie le CHEMIN et non un booléen : `couvert()` identifiait déjà le manifeste et le jetait,
    alors que c'est précisément la preuve dont la phase 1 a besoin pour décider de dé-vendoriser —
    elle montre que le dépôt a déjà un motif qui marche, dans un fichier nommé.

    Plusieurs manifestes peuvent couvrir le même répertoire. Il en faut UN, toujours le même :
    sinon `coveredBy` suit l'ordre d'os.walk, la sortie change entre deux exécutions sur un dépôt
    que personne n'a touché, et un lecteur qui compare deux évaluations voit une différence qui
    n'en est pas une. La règle est donc : le manifeste le plus PROCHE l'emporte (répertoire le
    plus profond, donc le plus spécifique à la bibliothèque), et à profondeur égale libman passe
    devant — c'est lui qui régit réellement `wwwroot/lib`, là où un package.json ne fait que
    nommer le même paquet.
    """
    candidats_couv = []          # (profondeur, rang, chemin du manifeste)
    for dir_parts, noms, manifeste in pkg_manifests:
        if cible[:len(dir_parts)] != dir_parts:
            continue                                  # ce manifeste ne régit pas ce chemin
        feuille = cible[-1]
        touche = feuille in noms
        if not touche and est_fichier:
            # `jquery-3.4.1.min.js` / `jquery.min.js` sont couverts par un `jquery` déclaré, mais
            # le nom doit s'arrêter net : sans la frontière, `jquery` couvrirait `jqueryui.js`.
            bas = feuille.lower()
            touche = any(bas.startswith(n.lower())
                         and bas[len(n):len(n) + 1] in ('.', '-', '_')
                         for n in noms if n)
        if touche:
            candidats_couv.append((len(dir_parts), 1, manifeste))
    for dest, dir_parts, manifeste in libman_dests:
        # L'un est préfixe de l'autre : `destination` peut viser le répertoire de la lib, ou un
        # sous-répertoire de celui-ci (`…/bootstrap/dist`), ou un fichier précis.
        n = min(len(dest), len(cible))
        if dest[:n] == cible[:n]:
            candidats_couv.append((len(dir_parts), 0, manifeste))
    if not candidats_couv:
        return None
    # Profondeur décroissante, puis rang croissant (libman=0 avant package.json=1), puis le chemin
    # pour que deux manifestes également proches et de même type restent départagés de façon
    # stable plutôt que par l'ordre de parcours.
    candidats_couv.sort(key=lambda c: (-c[0], c[1], c[2]))
    return candidats_couv[0][2]


vendored_assets = []
candidats = []
for dirpath, dirnames, filenames in os.walk('.'):
    # La SEULE utilisation de l'exception : ici un sous-module sous `wwwroot/{lib,vendor}` est la
    # copie vendorisée qu'on cherche, pas un projet étranger.
    dirnames[:] = prune(dirpath, dirnames, garder_vendor=True)
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
    # …mais seulement les fichiers qui SONT des assets. Un `wwwroot/lib/` par ailleurs vide ne
    # contient souvent qu'un `.gitkeep`, et le signaler attacherait la promesse de cette clé
    # (« rien ne surveille ceci, une CVE y serait invisible ») à un fichier témoin. Idem pour un
    # README ou un `.git` de sous-module.
    for f in filenames:
        if Path(f).suffix.lower() in ASSET_EXT:
            candidats.append((parts + (f,), None, True))

# Les manifestes ne sont tous connus qu'à la fin du parcours : un `package.json` peut apparaître
# après le répertoire qu'il déclare.
for cible, disque, est_fichier in candidats:
    manifeste = couvert(cible, est_fichier)
    vendored_assets.append({
        'path': '/'.join(cible),
        'files': 1 if est_fichier else count_files(disque),
        'coveredByManifest': manifeste is not None,
        'coveredBy': manifeste,
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
    'excludedFromWalk': [{'path': p, 'reason': r} for p, r in sorted(ECARTES.items())],
}, indent=2, ensure_ascii=False))
PY
