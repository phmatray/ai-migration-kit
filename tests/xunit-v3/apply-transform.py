#!/usr/bin/env python3
"""Apply the documented xunit v2 -> v3 transform to a COPY of a .NET app.

This is the executable form of `skills/legacy-upgrade/references/xunit-v3-migration.md`.
The reference states the rule; this script is the witness that the rule works — the golden
test (`tests/xunit-v3/test.sh`) runs it against a scratch copy of `samples/LegacyShop` and
then counts the tests that actually execute.

  usage: apply-transform.py <app-dir> [--skip-output-type] [--tfm net10.0]

`--skip-output-type` deliberately omits `<OutputType>Exe</OutputType>` so the test can pin
what happens when the single most likely mistake is made. Never pass it in real migrations.

The pinned xunit.v3 version below is this test's witness, not a recommendation: a real
migration resolves the current version from the live feed (context7), as the reference says.
"""
import argparse
import re
import sys
from pathlib import Path

XUNIT_V3_VERSION = "3.2.2"

# Coverage does NOT survive the platform change on its own: under MTP the VSTest collector
# (`--collect:"XPlat Code Coverage"`) is ignored and produces no file at all, silently. The MTP
# coverage extension is what puts cobertura back, so the transform installs it.
#
# ⚠ The major line must match the Microsoft.Testing.Platform version the test framework brings.
# xunit.v3 3.2.2 is on MTP v1, so CodeCoverage stays on the 17.x line; 18.x targets MTP 2.x and
# fails at run time with `TypeLoadException: Could not load type '…IDataConsumer'`.
COVERAGE_EXT_VERSION = "17.14.2"

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


def transform_test_csproj(text: str, with_output_type: bool) -> str:
    # 1. Drop the v2 package references, then any ItemGroup they left empty.
    text = drop_packages(text, DROP)
    text = re.sub(r"[ \t]*<ItemGroup>\s*</ItemGroup>\s*\n", "", text)

    # 2. Add the v3 packages in their own ItemGroup, above the first remaining one.
    new_refs = [
        f'<PackageReference Include="Microsoft.Testing.Extensions.CodeCoverage"'
        f' Version="{COVERAGE_EXT_VERSION}" />',
        f'<PackageReference Include="xunit.v3" Version="{XUNIT_V3_VERSION}" />',
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


def verify_transformed(text: str, with_output_type: bool) -> list:
    """Post-conditions. A transform that silently did nothing is the worst outcome here, so the
    script asserts its own work instead of trusting the substitutions to have matched."""
    problems = []
    if "xunit.v3" not in text:
        problems.append("xunit.v3 reference missing")
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
    args = ap.parse_args()

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
                text = transform_test_csproj(text, with_output_type=not args.skip_output_type)
            except RuntimeError as exc:
                print(f"{csproj}: {exc}", file=sys.stderr)
                return 1
            problems = verify_transformed(text, with_output_type=not args.skip_output_type)
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
