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

# The v2 packages the transform removes. `xunit` and `xunit.runner.visualstudio` are replaced
# by `xunit.v3` (which brings its own Microsoft Testing Platform runner); Microsoft.NET.Test.Sdk
# is the VSTest host and has no role left under MTP.
DROP = ("xunit", "xunit.runner.visualstudio", "xunit.abstractions", "Microsoft.NET.Test.Sdk")

NEW_PROPS = "<TestingPlatformDotnetTestSupport>true</TestingPlatformDotnetTestSupport>"


def is_test_project(text: str) -> bool:
    return bool(re.search(r'PackageReference\s+Include="(xunit|Microsoft\.NET\.Test\.Sdk)"', text))


def retarget(text: str, tfm: str) -> str:
    return re.sub(r"(<TargetFrameworks?>)[^<]+(</TargetFrameworks?>)", rf"\1{tfm}\2", text)


def transform_test_csproj(text: str, with_output_type: bool) -> str:
    # 1. Drop the v2 package references, then any ItemGroup they left empty.
    for pkg in DROP:
        text = re.sub(
            rf'[ \t]*<PackageReference\s+Include="{re.escape(pkg)}"[^>]*/>\s*\n', "", text
        )
    text = re.sub(r"[ \t]*<ItemGroup>\s*</ItemGroup>\s*\n", "", text)

    # 2. Add xunit.v3 in its own ItemGroup, before the first remaining ItemGroup (or at the end).
    new_group = (
        f'  <ItemGroup>\n'
        f'    <PackageReference Include="Microsoft.Testing.Extensions.CodeCoverage"'
        f' Version="{COVERAGE_EXT_VERSION}" />\n'
        f'    <PackageReference Include="xunit.v3" Version="{XUNIT_V3_VERSION}" />\n'
        f'  </ItemGroup>\n\n'
    )
    if "<ItemGroup>" in text:
        text = text.replace("  <ItemGroup>", new_group + "  <ItemGroup>", 1)
    else:
        text = text.replace("</Project>", new_group + "</Project>", 1)

    # 3. The properties that make it an MTP test executable. OutputType=Exe is the load-bearing
    #    one: xunit.v3 refuses to build a v3 test project that is still a library.
    props = [NEW_PROPS]
    if with_output_type:
        props.insert(0, "<OutputType>Exe</OutputType>")
    block = "".join(f"    {p}\n" for p in props)
    text = text.replace("  </PropertyGroup>", block + "  </PropertyGroup>", 1)
    return text


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
            text = transform_test_csproj(text, with_output_type=not args.skip_output_type)
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
