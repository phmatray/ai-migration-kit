#!/usr/bin/env python3
"""Apply the documented xunit v2 -> v3 transform to a COPY of a .NET app.

This is the executable form of `skills/legacy-upgrade/references/xunit-v3-migration.md`.
The reference states the rule; this script is the witness that the rule works — the golden
test (`tests/xunit-v3/test.sh`) runs it against a scratch copy of `samples/LegacyShop` and
then counts the tests that actually execute.

  usage: apply-transform.py <app-dir> [--skip-output-type] [--tfm net10.0]
                            [--coverage-version 17.14.2]

`--skip-output-type` deliberately omits `<OutputType>Exe</OutputType>` so the test can pin
what happens when the single most likely mistake is made. `--coverage-version` lets the test
inject a deliberately mismatched pair. Never pass either in a real migration — and note they
are FLAGS, not environment variables, so nothing a shell happens to carry can steer this
script.

The pinned xunit.v3 version below is this test's witness, not a recommendation: a real
migration resolves the current version from the live feed (context7), as the reference says.
What is NOT free to drift is the *pairing* — the xunit package and the MTP coverage extension must
sit on the same Microsoft.Testing.Platform line. `MTP_LINE` states that rule, keyed on the xunit
PACKAGE ID (`xunit.v3` vs `xunit.v3.mtp-v2` — both major 3, opposite MTP lines), and
`validate_pairing` enforces it, because the mismatch is invisible until a test run dies.
"""
import argparse
import re
import sys
from pathlib import Path

# The package id the transform writes, and its version. The id is load-bearing: xunit ships TWO
# parallel lines at the SAME major, and the id — not the version — selects the Microsoft.Testing
# .Platform major. Measured against nuget.org (`*.nuspec` on api.nuget.org/v3-flatcontainer):
#
#   xunit.v3        3.2.2 -> xunit.v3.mtp-v1      -> Microsoft.Testing.Platform 1.9.1
#   xunit.v3.mtp-v2 3.2.2 -> xunit.v3.core.mtp-v2 -> Microsoft.Testing.Platform 2.0.2
#
# Both are major 3, and `xunit.v3.mtp-v2` 3.2.0/3.2.1/3.2.2 are STABLE releases — so a map keyed on
# the major is not merely incomplete, it is inverted: it would refuse the correct mtp-v2 + 18.x
# pair and wave through the broken mtp-v2 + 17.x one.
XUNIT_V3_PACKAGE = "xunit.v3"
XUNIT_V3_VERSION = "3.2.2"

# xunit package id -> the Microsoft.Testing.Platform MAJOR LINE it binds to. This is the actual
# invariant; every expected version below is derived from it, so a new xunit line means one entry.
MTP_LINE = {
    "xunit.v3": 1,         # -> xunit.v3.mtp-v1,      Microsoft.Testing.Platform 1.x
    "xunit.v3.mtp-v2": 2,  # -> xunit.v3.core.mtp-v2, Microsoft.Testing.Platform 2.x
}

# Most of the family versions AS the platform line: Microsoft.Testing.Platform itself,
# …Platform.MSBuild, …Extensions.Telemetry and …Extensions.TrxReport.Abstractions are all 1.x
# alongside MTP v1 and 2.x alongside MTP v2 (measured from xunit.v3.core.mtp-v{1,2} 3.2.2's nuspecs).
#
# CodeCoverage is the one exception, and it is not a typo: it kept the numbering of its VSTest
# ancestor, so the same two lines are 17.x and 18.x. Modelling that as a per-package override keeps
# the quirk in one place — a single flat "expected major" table would have to repeat the line
# concept for every package, and would be wrong for whichever group it did not describe.
COVERAGE_PACKAGE = "Microsoft.Testing.Extensions.CodeCoverage"
# Keyed lower-case: NuGet package ids are case-INSENSITIVE, and these ids are read out of real
# csproj text where `microsoft.testing.extensions.codecoverage` is just as legal. An exact-case key
# would drop a case variant into the permissive branch below and invert the guard for it —
# `drop_packages` already lowercases both sides for the same reason.
EXTENSION_MAJOR = {
    COVERAGE_PACKAGE.lower(): {1: 17, 2: 18},
}


def expected_major(package: str, line: int) -> int:
    """The major `package` must be on to sit with Microsoft.Testing.Platform `line`.

    Unlisted packages follow the line. That is deliberately permissive: refusing an extension
    nobody has enumerated would block packages that are perfectly fine, and the failure this module
    guards is a *mismatch*, not an unknown name.
    """
    overrides = EXTENSION_MAJOR.get(package.lower())
    if overrides is None:
        return line
    try:
        return overrides[line]
    except KeyError:
        # A package is listed in EXTENSION_MAJOR precisely BECAUSE its majors are not the
        # platform's, so falling back to the line here would invent a version. Adding a line to
        # MTP_LINE alone must fail loudly rather than quietly accept `3.0.0` for CodeCoverage.
        raise ValueError(
            f"{package} does not follow the platform numbering, and EXTENSION_MAJOR has no entry "
            f"for Microsoft.Testing.Platform {line}.x. Add one — assuming {line}.x would be a "
            f"guess about a package listed here for not following that rule."
        ) from None


# Coverage does NOT survive the platform change on its own: under MTP the VSTest collector
# (`--collect:"XPlat Code Coverage"`) is ignored and produces no file at all, silently. The MTP
# coverage extension is what puts cobertura back, so the transform installs it.
#
# Overridable only by `--coverage-version`, never by the environment. The golden test needs to inject
# a bad pair; an env var would have granted that to every OTHER caller too, including a hand-run
# migration whose shell happened to carry the variable — and when the stray value shares the expected
# major, validate_pairing waves it through and the substitution is completely silent.
COVERAGE_EXT_VERSION = "17.14.2"


# A NuGet version as it may appear in a csproj attribute. Anchored at both ends on purpose — the
# value reaches an XML attribute through an f-string, so a partial match would let
# `17.0.0" /><PackageReference Include="…` through.
#
# `[0-9]`, not `\d`: `\d` matches Unicode decimal digits, so `1７.0.0` (fullwidth 7) would pass here
# AND through int() — and then NuGet cannot parse the attribute the guard just approved.
#
# Floating (`17.14.*`) and build metadata (`17.14.2+build`) are accepted deliberately: the reference
# tells migrators the rule constrains the major LINE, not the patch, so pinning `17.*` is following
# its advice. A guard that refused it would fight the guide it enforces.
VERSION_RE = re.compile(
    r"[0-9]+(?:\.[0-9]+)*(?:\.\*)?(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\Z"
)


def _major_of(version: str) -> int:
    """Major as an INT: '017.14.2' and '17.14.2' are the same line, and a refusal that claims
    otherwise ('the 017.x line') is exactly the confusing diagnostic this module exists to kill."""
    head = version.split(".", 1)[0].strip()
    if not head.isdigit():
        raise ValueError(f"cannot read a major version from {version!r}")
    return int(head)


def validate_pairing(xunit_package: str, version: str,
                     package: str | None = None,
                     xunit_version: str | None = None) -> None:
    """Refuse a Microsoft.Testing.* package that straddles the MTP line the xunit package binds to.

    Keyed on the xunit PACKAGE ID, never its version: `xunit.v3` and `xunit.v3.mtp-v2` are both
    on major 3 today and sit on opposite MTP lines, so a version-keyed rule gets it exactly
    backwards.

    `package` defaults to the coverage extension — the one this transform writes — but any member
    of the family can be checked, because they all cross the same v1/v2 boundary.

    The failure this prevents is the nastiest kind available here: `dotnet restore` succeeds,
    the build succeeds, and the test host dies at run time with a `TypeLoadException` naming an
    interface nobody recognises. Nothing in that stack trace names either package, so the refusal
    names both — that is the part a future reader actually needs.
    """
    # Resolved at CALL time, like transform_test_csproj's: test.sh drives this module by patching
    # module attributes in-process, and a def-time default would keep naming the old value.
    package = COVERAGE_PACKAGE if package is None else package
    xunit_version = XUNIT_V3_VERSION if xunit_version is None else xunit_version

    if not VERSION_RE.match(version):
        raise ValueError(
            f"not a version: {version!r}. This string is interpolated straight into a "
            f"csproj attribute, so anything shaped otherwise either produces an unusable pin or "
            f"breaks out of the attribute entirely."
        )
    line = MTP_LINE.get(xunit_package)
    if line is None:
        raise ValueError(
            f"unknown xunit.v3 package id {xunit_package!r}: extend MTP_LINE with the "
            f"Microsoft.Testing.Platform line it targets. Guessing a compatible major "
            f"would reintroduce the run-time failure the map prevents."
        )
    expected = expected_major(package, line)
    got = _major_of(version)
    if got != expected:
        raise ValueError(
            f"incompatible test platform pair: {xunit_package} {xunit_version} runs on "
            f"Microsoft.Testing.Platform {line}.x, which is served by {package} {expected}.x — "
            f"but {version} is on the {got}.x line. Both bind to Microsoft.Testing.Platform, so "
            f"this restores and builds clean, then dies at run time with "
            f"\"TypeLoadException: Could not load type '…IDataConsumer'\". "
            f"Move every leg in the same change (see MTP_LINE / EXTENSION_MAJOR)."
        )


# The v2 packages the transform removes. `xunit` and `xunit.runner.visualstudio` are replaced by
# `xunit.v3` (which brings its own Microsoft Testing Platform runner); Microsoft.NET.Test.Sdk is the
# VSTest host and `coverlet.collector` the VSTest coverage collector — neither has a role under MTP,
# and leaving the adapter behind produces a half-swapped test host, the exact failure this guards.
DROP = ("xunit", "xunit.runner.visualstudio", "xunit.abstractions",
        "Microsoft.NET.Test.Sdk", "coverlet.collector")

NEW_PROPS = "<TestingPlatformDotnetTestSupport>true</TestingPlatformDotnetTestSupport>"

# A PackageReference has two legal shapes and `dotnet new xunit` emits BOTH: self-closing, and an
# element with <PrivateAssets>/<IncludeAssets> children. Matching only the first silently leaves
# the VSTest adapter in place next to xunit.v3.
PKG_REF = re.compile(
    r"[ \t]*<PackageReference\b([^>]*?)(?:/>|>.*?</PackageReference>)[ \t]*\n?", re.S
)
PKG_ATTR = re.compile(r'(\w+)\s*=\s*"([^"]*)"')


def is_test_project(text: str) -> bool:
    return bool(re.search(r'PackageReference\s+Include="(xunit|Microsoft\.NET\.Test\.Sdk)"', text))


def _below_v3_floor(tfm: str) -> bool:
    """xunit.v3 needs .NET 8.0+ or .NET Framework 4.7.2+. Only those get retargeted."""
    m = re.fullmatch(r"net(\d+)\.(\d+)", tfm)
    if m:
        return int(m.group(1)) < 8
    return tfm.startswith(("netcoreapp", "netstandard", "portable-", "uap"))


def retarget(text: str, tfm: str) -> str:
    """Bump only the TFMs below the v3 floor, and never collapse a multi-targeted list.

    Rewriting `<TargetFrameworks>net6.0;net8.0</TargetFrameworks>` to a single TFM drops a
    published library's other legs — the defect that took repo-audit/bump_tfm.py out of service.
    """
    def repl(m):
        tokens = [t.strip() for t in m.group(2).split(";") if t.strip()]
        out, seen = [], set()
        for t in tokens:
            new = tfm if _below_v3_floor(t) else t
            if new not in seen:
                seen.add(new)
                out.append(new)
        return m.group(1) + ";".join(out) + m.group(3)

    return re.sub(r"(<TargetFrameworks?>)([^<]+)(</TargetFrameworks?>)", repl, text)


def drop_packages(text: str, ids) -> str:
    wanted = {i.lower() for i in ids}

    def repl(m):
        attrs = dict(PKG_ATTR.findall(m.group(1)))
        pid = (attrs.get("Include") or attrs.get("Update") or "").lower()
        return "" if pid in wanted else m.group(0)

    return PKG_REF.sub(repl, text)


def _insert_before(text: str, closing_tag: str, lines) -> str | None:
    """Insert `lines` just above the first `closing_tag`, matching its actual indentation.

    Keying off a literal two-space indent made this a no-op on any csproj formatted differently —
    and the script still exited 0 claiming success, producing the very OutputType trap it exists
    to prevent. Returns None when the anchor is absent so the caller can fail loudly.
    """
    m = re.search(rf"^([ \t]*)</{closing_tag}>", text, re.M)
    if not m:
        return None
    indent = m.group(1)
    inner = indent + "  "
    block = "".join(f"{inner}{line}\n" for line in lines)
    return text[: m.start()] + block + text[m.start():]


def transform_test_csproj(text: str, with_output_type: bool,
                          coverage_version: str | None = None) -> str:
    # Resolved at CALL time, not bound at def time: a default of `COVERAGE_EXT_VERSION` would
    # capture the module constant once, so a caller that patches `mod.COVERAGE_EXT_VERSION` — the
    # natural way to exercise the other MTP line in-process — would silently get the stale pin
    # written AND validated, and its assertion would pass for the wrong version.
    coverage_version = COVERAGE_EXT_VERSION if coverage_version is None else coverage_version

    # The guard belongs at the point that actually emits the pair, not only in main(): this
    # function is importable, and a caller reaching it directly would otherwise write both
    # PackageReferences with no pairing check at all. It validates the version about to be
    # WRITTEN, not the module default — otherwise `--coverage-version` would slip past it.
    validate_pairing(XUNIT_V3_PACKAGE, coverage_version)

    # 1. Drop the v2 package references, then any ItemGroup they left empty.
    text = drop_packages(text, DROP)
    text = re.sub(r"[ \t]*<ItemGroup>\s*</ItemGroup>\s*\n", "", text)

    # 2. Add the v3 packages in their own ItemGroup, above the first remaining one.
    new_refs = [
        f'<PackageReference Include="Microsoft.Testing.Extensions.CodeCoverage"'
        f' Version="{coverage_version}" />',
        f'<PackageReference Include="{XUNIT_V3_PACKAGE}" Version="{XUNIT_V3_VERSION}" />',
    ]
    m = re.search(r"^([ \t]*)<ItemGroup>", text, re.M)
    if m:
        indent = m.group(1)
        group = (
            f"{indent}<ItemGroup>\n"
            + "".join(f"{indent}  {r}\n" for r in new_refs)
            + f"{indent}</ItemGroup>\n\n"
        )
        text = text[: m.start()] + group + text[m.start():]
    else:
        group = (
            "  <ItemGroup>\n"
            + "".join(f"    {r}\n" for r in new_refs)
            + "  </ItemGroup>\n\n"
        )
        text = text.replace("</Project>", group + "</Project>", 1)

    # 3. The properties that make it an MTP test executable. OutputType=Exe is the load-bearing
    #    one: xunit.v3 refuses to build a v3 test project that is still a library.
    props = [NEW_PROPS]
    if with_output_type:
        props.insert(0, "<OutputType>Exe</OutputType>")
    inserted = _insert_before(text, "PropertyGroup", props)
    if inserted is None:
        raise RuntimeError("no </PropertyGroup> to anchor the MTP properties on")
    return inserted


def verify_transformed(text: str, with_output_type: bool,
                       coverage_version: str | None = None) -> list:
    """Post-conditions. A transform that silently did nothing is the worst outcome here, so the
    script asserts its own work instead of trusting the substitutions to have matched."""
    coverage_version = COVERAGE_EXT_VERSION if coverage_version is None else coverage_version
    problems = []
    if XUNIT_V3_PACKAGE not in text:
        problems.append(f"{XUNIT_V3_PACKAGE} reference missing")
    # Coverage is the half that fails SILENTLY: under MTP the VSTest collector is ignored, so a
    # migration that lost this reference still builds, still runs its tests, and simply reports no
    # coverage. Nothing downstream would call that an error — which is why it is asserted here.
    if not re.search(
        rf'PackageReference\s+Include="Microsoft\.Testing\.Extensions\.CodeCoverage"'
        rf'\s+Version="{re.escape(coverage_version)}"', text
    ):
        problems.append(
            f"Microsoft.Testing.Extensions.CodeCoverage {coverage_version} reference missing — "
            f"coverage would silently vanish under MTP"
        )
    if NEW_PROPS not in text:
        problems.append("TestingPlatformDotnetTestSupport missing")
    if with_output_type and "<OutputType>Exe</OutputType>" not in text:
        problems.append("OutputType=Exe missing — the project would not run any test")
    for pkg in DROP:
        if re.search(rf'PackageReference\s+Include="{re.escape(pkg)}"', text):
            problems.append(f"{pkg} survived the transform")
    return problems


def rewrite_usings(root: Path) -> int:
    """ITestOutputHelper moved from Xunit.Abstractions to Xunit in v3."""
    touched = 0
    for cs in root.rglob("*.cs"):
        if any(part in ("bin", "obj") for part in cs.parts):
            continue
        text = cs.read_text(encoding="utf-8")
        if "using Xunit.Abstractions;" not in text:
            continue
        if re.search(r"^using Xunit;$", text, re.M):
            # `using Xunit;` already present — drop the stale one rather than duplicate it.
            new = re.sub(r"^using Xunit\.Abstractions;\n", "", text, flags=re.M)
        else:
            new = re.sub(r"^using Xunit\.Abstractions;$", "using Xunit;", text, flags=re.M)
        cs.write_text(new, encoding="utf-8")
        touched += 1
    return touched


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("app_dir", type=Path)
    ap.add_argument("--skip-output-type", action="store_true")
    ap.add_argument("--tfm", default="net10.0")
    ap.add_argument(
        "--coverage-version", default=COVERAGE_EXT_VERSION,
        help="Microsoft.Testing.Extensions.CodeCoverage version to write. Test-only: it exists so "
             "the golden test can inject a deliberately mismatched pair. Never pass it in a real "
             "migration — resolve the version from the live feed instead.",
    )
    args = ap.parse_args()

    # Before anything is read or written: the pair this run is about to bake into a csproj must
    # agree. Parsed first, so `--help` still prints usage when the pair is deliberately bad.
    try:
        validate_pairing(XUNIT_V3_PACKAGE, args.coverage_version)
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 1

    root = args.app_dir
    if not root.is_dir():
        print(f"not a directory: {root}", file=sys.stderr)
        return 2

    tests_seen = 0
    for csproj in root.rglob("*.csproj"):
        if any(part in ("bin", "obj") for part in csproj.parts):
            continue
        text = csproj.read_text(encoding="utf-8")
        # Every project is retargeted: the v3 floor is net8.0 (or net472 on Framework), so a
        # v2 -> v3 move only ever happens on a solution that already cleared phase 3.
        text = retarget(text, args.tfm)
        if is_test_project(text):
            try:
                text = transform_test_csproj(text, with_output_type=not args.skip_output_type,
                                             coverage_version=args.coverage_version)
            except RuntimeError as exc:
                print(f"{csproj}: {exc}", file=sys.stderr)
                return 1
            problems = verify_transformed(text, with_output_type=not args.skip_output_type,
                                          coverage_version=args.coverage_version)
            if problems:
                print(f"{csproj}: transform did not apply cleanly:", file=sys.stderr)
                for p in problems:
                    print(f"  - {p}", file=sys.stderr)
                return 1
            tests_seen += 1
        csproj.write_text(text, encoding="utf-8")

    if tests_seen == 0:
        print("no test project found — nothing to migrate", file=sys.stderr)
        return 1

    rewritten = rewrite_usings(root)
    print(f"transformed {tests_seen} test project(s), rewrote {rewritten} using-directive file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
