#!/usr/bin/env bash
# Golden test for scripts/host-adapters.py — the generator and drift check for the files that carry
# one of the kit's sources to another host (#525, #526): AGENTS.md's rule copies for Cursor,
# Windsurf, Cline, Kiro, GitHub Copilot and Antigravity, the TOML commands and extension manifest
# Gemini CLI reads, and the invariants the plugin manifests and the host table must keep.
#
# What this suite guards:
#   A. the REAL repository                      -> check exits 0, every copy in step
#   B. one copy edited in a scratch tree        -> exit 1, naming that copy and no other
#   C. build in that tree, then check           -> exit 0 — build restores what check refuses
#   D. a copy's whole folder deleted            -> exit 1, naming it; build recreates the folder
#   E. a scratch tree with no AGENTS.md         -> exit 2, no verdict, never a pass
#   F. a copy with CRLF line endings            -> exit 0 (a Windows checkout is not drift)
#  F2. a UTF-16 copy / a UTF-16 AGENTS.md       -> exit 1 naming it / exit 2 — never a traceback
#  F4. a CRLF AGENTS.md                         -> exit 0 (the source is normalised too)
#   G. no subcommand                            -> exit 2 (usage)
#   H. each host's front matter, on the real copies, as the host documents it
#   I. a hooks/hooks.json in the tree           -> exit 1, naming it (Gemini and Copilot auto-load it)
#   J. a manifest naming a hooks map that does not exist -> exit 1, naming the path
#   K. a manifest at another version than the release-please manifest -> exit 1, naming it
#   L. a versioned manifest missing from release-please's extra-files -> exit 1, naming it
#   M. a TOML command edited by hand            -> exit 1, naming it AND the .md it is built from
#   N. a server added to .mcp.json alone        -> exit 1, naming gemini-extension.json
#   O. the live TOML commands parse, carry description + prompt, and spell {{args}}
#   P. gemini-extension.json, against the shape Gemini CLI documents
#   Q. package.json declares the skills for pi and stays private
#   R. README.md missing a plugin host's install line -> exit 1, naming README.md and the host
#   S. a host table row naming an adapter that does not exist -> exit 1, naming the adapter
#
# The seam is the check's exit code and its STDOUT: a refusal is named there, and stderr is read
# only to prove no traceback escaped. Expected paths and values are literals here, never read back
# out of the script — a test that recomputed them the way the script does could never disagree with
# it (tautological). Section lines carry a label, never a fraction.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/scripts/host-adapters.py"
. "$REPO/tests/_lib.sh" || {
  echo "FAIL: cannot source $REPO/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$REPO"
kit_guard kit_guard_samples_unchanged
WORK=$(kit_scratch)

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

COPIES=".cursor/rules/ai-migration-kit.mdc .windsurf/rules/ai-migration-kit.md .clinerules/ai-migration-kit.md .kiro/steering/ai-migration-kit.md .github/copilot-instructions.md .agents/rules/ai-migration-kit.md"
# What the invariants read, beside the copies: the manifests, the files their paths name,
# release-please's two files, the host table and the README it is checked against. `skills/` only
# has to exist for a manifest's `skills` path to resolve.
SOURCES=".claude-plugin/plugin.json .codex-plugin/plugin.json .github/plugin/plugin.json gemini-extension.json package.json hooks/claude-hooks.json .mcp.json .release-please-manifest.json release-please-config.json docs/_data/hosts.yml README.md"

# scratch_tree <dir> — a copy of what the check reads, and nothing else.
scratch_tree() {
  local d="$1" f
  mkdir -p "$d/skills"
  cp "$REPO/AGENTS.md" "$d/AGENTS.md"
  cp -R "$REPO/commands" "$d/commands"
  for f in $COPIES $SOURCES; do
    mkdir -p "$d/$(dirname "$f")"
    cp "$REPO/$f" "$d/$f" 2>/dev/null || true
  done
}

# run_check <repo> [subcommand] — sets OUT (stdout), ERR (stderr) and RC.
run_check() {
  OUT=$(python3 "$CHECK" --repo "$1" "${2:-check}" 2>"$WORK/stderr")
  RC=$?
  ERR=$(cat "$WORK/stderr")
}

names() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
no_traceback() { case "$ERR" in *Traceback*) bad "$1 produced a traceback: $ERR" ;; *) ok "$1: no traceback" ;; esac; }
utf16() { python3 -c 'import sys; open(sys.argv[2], "w", encoding="utf-16").write(open(sys.argv[1], encoding="utf-8").read())' "$1" "$2"; }
crlf() { awk '{ printf "%s\r\n", $0 }' "$1" > "$2"; }
# jedit <file> <python statement on d> — edit one JSON file in place, for a mutation case.
jedit() { python3 -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p, encoding="utf-8")); exec(sys.argv[2]); json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)' "$1" "$2"; }

[ -f "$CHECK" ] || { echo "FAIL: $CHECK does not exist"; exit 1; }

echo "== A. the real repository =="
run_check "$REPO"
[ "$RC" -eq 0 ] && ok "check exits 0 on the live tree" || bad "check exited $RC on the live tree: $OUT $ERR"

echo "== B. one edited copy is refused, by name =="
T="$WORK/b"; scratch_tree "$T"
printf '\nA line nobody generated.\n' >> "$T/.clinerules/ai-migration-kit.md"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC, want 1: $OUT $ERR"
names ".clinerules/ai-migration-kit.md" && ok "names .clinerules/ai-migration-kit.md on stdout" || bad "stdout does not name the edited copy: $OUT"
names ".kiro/steering/ai-migration-kit.md" && bad "names an untouched copy: $OUT" || ok "names no untouched copy"

echo "== C. build restores it =="
run_check "$T" build
[ "$RC" -eq 0 ] && ok "build exits 0" || bad "build exited $RC: $ERR"
run_check "$T"
[ "$RC" -eq 0 ] && ok "check exits 0 after build" || bad "check exited $RC after build: $OUT"

echo "== D. a copy's whole folder deleted is drift, and build recreates it =="
T="$WORK/d"; scratch_tree "$T"
rm -r "$T/.kiro"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC, want 1: $OUT $ERR"
names ".kiro/steering/ai-migration-kit.md" && ok "names the missing copy on stdout" || bad "stdout does not name the missing copy: $OUT"
run_check "$T" build
[ "$RC" -eq 0 ] && ok "build recreates the missing folder" || bad "build exited $RC into a missing folder: $ERR"
run_check "$T"
[ "$RC" -eq 0 ] && ok "check exits 0 after build" || bad "check exited $RC after build: $OUT"

echo "== E. no AGENTS.md, no verdict =="
T="$WORK/e"; scratch_tree "$T"
rm "$T/AGENTS.md"
run_check "$T"
[ "$RC" -eq 2 ] && ok "exit 2" || bad "exit $RC, want 2: $OUT $ERR"
no_traceback "a missing AGENTS.md"

echo "== F. CRLF is not drift =="
T="$WORK/f"; scratch_tree "$T"
crlf "$REPO/.clinerules/ai-migration-kit.md" "$T/.clinerules/ai-migration-kit.md"
run_check "$T"
[ "$RC" -eq 0 ] && ok "a CRLF copy is in step" || bad "exit $RC on a CRLF copy: $OUT"

echo "== F2. a non-UTF-8 file: a copy is drift, the source is no verdict =="
T="$WORK/f2"; scratch_tree "$T"
utf16 "$REPO/.windsurf/rules/ai-migration-kit.md" "$T/.windsurf/rules/ai-migration-kit.md"
run_check "$T"
[ "$RC" -eq 1 ] && ok "a UTF-16 copy exits 1" || bad "a UTF-16 copy exited $RC, want 1: $OUT $ERR"
names ".windsurf/rules/ai-migration-kit.md" && ok "names the UTF-16 copy on stdout" || bad "stdout does not name the UTF-16 copy: $OUT"
no_traceback "a UTF-16 copy"
T="$WORK/f3"; scratch_tree "$T"
utf16 "$REPO/AGENTS.md" "$T/AGENTS.md"
run_check "$T"
[ "$RC" -eq 2 ] && ok "a UTF-16 AGENTS.md exits 2" || bad "a UTF-16 AGENTS.md exited $RC, want 2: $OUT $ERR"
no_traceback "a UTF-16 AGENTS.md"

echo "== F4. a CRLF AGENTS.md is not drift =="
T="$WORK/f4"; scratch_tree "$T"
crlf "$REPO/AGENTS.md" "$T/AGENTS.md"
run_check "$T"
[ "$RC" -eq 0 ] && ok "LF copies are in step with a CRLF source" || bad "exit $RC with a CRLF AGENTS.md: $OUT"

echo "== G. usage =="
python3 "$CHECK" --repo "$REPO" > /dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "no subcommand exits 2" || bad "no subcommand exited $RC"

echo "== H. each host's front matter =="
[ "$(head -1 "$REPO/.cursor/rules/ai-migration-kit.mdc")" = "---" ] \
  && grep -qx 'alwaysApply: true' "$REPO/.cursor/rules/ai-migration-kit.mdc" \
  && ok "Cursor: an always-applied .mdc rule" || bad "Cursor rule lacks 'alwaysApply: true' front matter"
grep -qx 'trigger: always_on' "$REPO/.windsurf/rules/ai-migration-kit.md" \
  && ok "Windsurf: trigger always_on" || bad "Windsurf rule lacks 'trigger: always_on'"
grep -qx 'inclusion: always' "$REPO/.kiro/steering/ai-migration-kit.md" \
  && ok "Kiro: inclusion always" || bad "Kiro steering lacks 'inclusion: always'"
for f in .clinerules/ai-migration-kit.md .github/copilot-instructions.md .agents/rules/ai-migration-kit.md; do
  [ "$(head -1 "$REPO/$f")" = "# AI Migration Kit" ] \
    && ok "$f: no front matter, opens on the heading" || bad "$f does not open on '# AI Migration Kit'"
done

echo "== I. the Claude hooks map stays off hooks/hooks.json =="
T="$WORK/i"; scratch_tree "$T"
printf '{"hooks": {}}\n' > "$T/hooks/hooks.json"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with a hooks/hooks.json, want 1: $OUT $ERR"
names "hooks/hooks.json" && ok "names hooks/hooks.json on stdout" || bad "stdout does not name hooks/hooks.json: $OUT"

echo "== J. a manifest naming a hooks map that does not exist =="
T="$WORK/j"; scratch_tree "$T"
jedit "$T/.claude-plugin/plugin.json" 'd["hooks"] = "./hooks/nope.json"'
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with a missing hooks map, want 1: $OUT $ERR"
names "./hooks/nope.json" && ok "names the missing path on stdout" || bad "stdout does not name ./hooks/nope.json: $OUT"

echo "== K. a manifest at another version than the release-please manifest =="
T="$WORK/k"; scratch_tree "$T"
jedit "$T/.codex-plugin/plugin.json" 'd["version"] = "0.0.1"'
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with a stale Codex version, want 1: $OUT $ERR"
names ".codex-plugin/plugin.json" && ok "names .codex-plugin/plugin.json on stdout" || bad "stdout does not name the stale manifest: $OUT"

echo "== L. a versioned manifest missing from release-please's extra-files =="
T="$WORK/l"; scratch_tree "$T"
jedit "$T/release-please-config.json" 'd["packages"]["."]["extra-files"] = [e for e in d["packages"]["."]["extra-files"] if e["path"] != ".github/plugin/plugin.json"]'
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with a manifest outside extra-files, want 1: $OUT $ERR"
names ".github/plugin/plugin.json" && ok "names .github/plugin/plugin.json on stdout" || bad "stdout does not name the unbumped manifest: $OUT"

echo "== M. a TOML command edited by hand is refused, naming its source =="
T="$WORK/m"; scratch_tree "$T"
printf '\n# edited by hand\n' >> "$T/commands/migrate.toml"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with an edited TOML command, want 1: $OUT $ERR"
names "commands/migrate.toml" && ok "names commands/migrate.toml on stdout" || bad "stdout does not name the edited command: $OUT"
names "commands/migrate.md" && ok "names its source, commands/migrate.md" || bad "the refusal does not name the TOML's source: $OUT"

echo "== N. a server added to .mcp.json alone leaves gemini-extension.json behind =="
T="$WORK/n"; scratch_tree "$T"
jedit "$T/.mcp.json" 'd["mcpServers"]["extra"] = {"type": "stdio", "command": "dnx", "args": ["Extra", "--yes"]}'
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with a server only in .mcp.json, want 1: $OUT $ERR"
names "gemini-extension.json" && ok "names gemini-extension.json on stdout" || bad "stdout does not name gemini-extension.json: $OUT"

echo "== O. the live TOML commands are what Gemini CLI reads =="
if python3 - "$REPO" > "$WORK/o.out" 2>&1 <<'PY'
import pathlib, sys, tomllib
repo = pathlib.Path(sys.argv[1])
mds = sorted((repo / "commands").glob("*.md"))
assert mds, "no commands/*.md"
for md in mds:
    toml = md.with_suffix(".toml")
    data = tomllib.loads(toml.read_text(encoding="utf-8"))
    assert set(data) == {"description", "prompt"}, f"{toml.name}: keys {sorted(data)}"
    assert "$ARGUMENTS" not in data["prompt"], f"{toml.name}: $ARGUMENTS survived"
m = tomllib.loads((repo / "commands" / "migrate.toml").read_text(encoding="utf-8"))
want = "Run the full seven-phase legacy upgrade pipeline (assess → verified production) powered by RoselineMCP"
assert m["description"] == want, m["description"]
assert "{{args}}" in m["prompt"], "migrate.toml: no {{args}} in the prompt"
PY
then ok "every commands/*.md has a TOML twin with description and prompt, and {{args}} for \$ARGUMENTS"
else bad "the TOML commands: $(cat "$WORK/o.out")"; fi

echo "== P. gemini-extension.json, as Gemini CLI documents it =="
if python3 - "$REPO" > "$WORK/p.out" 2>&1 <<'PY'
import json, pathlib, sys
ext = json.loads((pathlib.Path(sys.argv[1]) / "gemini-extension.json").read_text(encoding="utf-8"))
assert ext["name"] == "ai-migration-kit", ext["name"]
assert ext["contextFileName"] == "AGENTS.md", ext["contextFileName"]
assert ext["mcpServers"]["roseline"] == {"command": "dnx", "args": ["RoselineMCP", "--yes"]}, ext["mcpServers"]
assert ext["mcpServers"]["adr"] == {"command": "dnx", "args": ["AdrMcp", "--yes"]}, ext["mcpServers"]
PY
then ok "name, AGENTS.md as context, and the two dnx servers without a type key"
else bad "gemini-extension.json: $(cat "$WORK/p.out")"; fi

echo "== Q. package.json declares the skills for pi, and stays private =="
[ "$(jq -r '.pi.skills[0]' "$REPO/package.json" 2>/dev/null)" = "./skills" ] \
  && [ "$(jq -r '.private' "$REPO/package.json" 2>/dev/null)" = "true" ] \
  && ok "pi.skills is ./skills and the package is private" || bad "package.json does not declare pi.skills ./skills, private"

echo "== R. README.md missing a plugin host's install line =="
T="$WORK/r"; scratch_tree "$T"
grep -vF 'gemini extensions install' "$REPO/README.md" > "$T/README.md"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with Gemini's line gone from README.md, want 1: $OUT $ERR"
names "README.md" && ok "names README.md on stdout" || bad "stdout does not name README.md: $OUT"
names "gemini-cli" && ok "names the host, gemini-cli" || bad "stdout does not name the host: $OUT"

echo "== S. a host table row naming an adapter that does not exist =="
T="$WORK/s"; scratch_tree "$T"
sed 's#adapter: package.json#adapter: nope.json#' "$REPO/docs/_data/hosts.yml" > "$T/docs/_data/hosts.yml"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with a missing adapter, want 1: $OUT $ERR"
names "nope.json" && ok "names the missing adapter on stdout" || bad "stdout does not name nope.json: $OUT"

if [ "$fails" -eq 0 ]; then
  echo "PASS: host-adapters — live tree, edit, rebuild, missing folder, no source, CRLF, encodings, usage, front matter, hooks map, versions, Gemini commands and extension, pi, host table"
else
  echo "FAIL: host-adapters — $fails assertion(s) failed"; exit 1
fi
