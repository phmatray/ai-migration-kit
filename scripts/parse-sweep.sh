#!/usr/bin/env bash
# parse-sweep.sh — every tests/<name>/test.sh must PARSE under the bash the developer actually has.
#
# Why this exists (#131). The repo profile names `./tests/<suite>/test.sh` as THE local fast path.
# `tests/renovate-config/test.sh` had never once run on macOS: it did not fail an assertion, it
# never reached one —
#
#     $ bash -n tests/renovate-config/test.sh
#     tests/renovate-config/test.sh: line 64: unexpected EOF while looking for matching `)'
#
# macOS still ships GNU bash 3.2.57 as /bin/bash and `#!/usr/bin/env bash` resolves to it, while CI
# runs ubuntu-latest (bash 5) where the same file parses and passes. So the suite was wired into CI,
# counted by ci-wiring-check.py, green on every run — and locally it contributed nothing. The same
# absence-shaped failure as #45, one layer down: a suite that cannot be PARSED looks exactly like a
# suite that passes.
#
# THE CONSTRUCT. bash 3.2 scans a `$( … )` command substitution WITHOUT honouring heredoc quoting.
# Every quote character in the body of a heredoc opened inside a command substitution is therefore
# read as a shell quote. If they do not pair within that body, the scanner is left mid-string and
# runs to end-of-file looking for the close. Measured on bash 3.2.57 — and the intuitive diagnoses
# are all wrong, which is why each control is spelled out here:
#
#     variant                                                           bash 3.2
#     two $(python3 - <<PY … PY) blocks, every quote paired             parses
#     an apostrophe inside a "…" string in the body                     parses  (it pairs)
#     an apostrophe in a body line that is a # comment                  parses  (bash sees the
#                                                                               comment too)
#     an apostrophe in a # glued to the previous token (no blank)       FAILS   (not a comment)
#     …the same, glued to a `)` or a `;` rather than to a letter        FAILS   (a metacharacter
#                                                                               does not open a
#                                                                               comment HERE)
#     r'…["\']…' — the quotes re-pair across the regex                  FAILS
#     the same line spelled PIN="$( … )" instead of PIN=$( … )          FAILS   (a $( … ) inside
#                                                                               "…" is scanned the
#                                                                               very same way)
#     TWO heredocs in ONE $( … ), each leaving one apostrophe live      parses  (they pair with
#                                                                               EACH OTHER)
#     the same heredoc NOT inside a command substitution                parses
#
# It is neither "too many heredocs" nor "Python in a heredoc". It is quote pairing, and only inside
# a command substitution. Three measured consequences shape the emulation below — each one was a
# hole in an earlier draft of this script, found by comparing it against the real parser:
#
#   * bash's comment rule applies inside the body, but the rule that applies HERE is the command
#     substitution scanner's, and it is NARROWER than the lexer's: `#` opens a comment only at the
#     start of the text, after a newline, or after a blank. bash 3.2's own source concedes the gap
#     ("Not exactly right yet; should handle shell metacharacters"), and `print("a")#it's` proves
#     it — a `#` glued to the `)` that ends nearly every Python statement is not a comment, and
#     that file does not parse.
#   * a `$( … )` opened INSIDE a "…" string is the same construct. `PIN="$(python3 - <<'PY'` — the
#     dominant spelling in this kit — carries the hazard exactly as the unquoted form does, so the
#     scan has to follow `$(` out of a double-quoted string and back into it at the `)`.
#   * the scan state carries across the WHOLE substitution, not per heredoc: bash is hunting for
#     the matching `)` and never restarts. Two bodies whose apostrophes pair with EACH OTHER parse
#     fine, so judging a body in isolation reddens correct code.
#
# WHAT THIS SCRIPT DOES — two halves, deliberately, because neither covers the other:
#
#   1. `bash -n` over every target, under the RUNNING bash ($BASH), reported with its version.
#      Catches anything this host's parser rejects, the #131 construct included. On bash >= 4 this
#      half is a NO-OP for #131 — bash 5 parses the broken form happily — which is exactly why the
#      banner names the version it measured. A green run on CI is not proof about bash 3.2.
#
#   2. A static scan for the construct itself, version-INDEPENDENT, so the guard is real on CI too.
#      It emulates the character scan bash 3.2 performs — backslash escapes outside quotes and
#      inside "…" but not inside '…'; `#` starts a comment only after a blank, a newline or nothing
#      — over the bodies of every heredoc opened inside one `$( … )`, taken TOGETHER, and refuses
#      when the substitution as a whole is left inside a string. It names the construct, rather
#      than leaving a reader with bash's "unexpected EOF", which points at the end of the file and
#      never at the line that did it.
#
# Half 2 is what a CI run enforces; half 1 is what makes the local fast path trustworthy. Dropping
# either one is how this comes back.
#
# KNOWN LIMITS. This emulates one parser's character scan; it is not a parser, so the list below is
# the guard's actual claim. Read it as the boundary of what a green run proves:
#   * backtick command substitution is not tracked — this kit uses `$( … )` throughout. A backtick
#     form carrying the hazard passes half 2 and is caught by half 1 on bash 3.2 only.
#   * at most one heredoc opener is recognised per line (the shape every suite here uses).
#   * the shell text BETWEEN two heredoc bodies of one substitution is not re-scanned in the state
#     the previous body left it in. bash does scan it; this carries the body state across it
#     instead, on the assumption that valid shell pairs its own quotes.
#   * one accumulator per substitution, so heredocs in a NESTED `$( $( … ) )` share it.
#   * PARENTHESES inside a substitution are not counted. bash 3.2 counts them: an unbalanced `(`
#     inside the substitution — including one whose `)` got swallowed by an unpaired quote, as in
#     `print('it\'s one')` — makes it run to EOF looking for the close. Measured: such a file fails
#     on 3.2 while this scan calls it clean. The heredoc bodies here are embedded Python, whose
#     parens balance, so the gap is narrow; it is a gap all the same.
#   * a `)` closing a `case` pattern inside a substitution is read as closing the substitution —
#     which is also what bash 3.2's own scanner does with it, so the file is suspect anyway.
#   * only `tests/*/test.sh` is swept by default; `scripts/`, `hooks/` and `skills/**/scripts/`
#     are not, though they ship to the same macOS developers. See docs/backlog.md.
#
# These cost a false NEGATIVE — the side to err on, because a guard that reddens CI on correct code
# gets deleted. Every one of them was measured against bash 3.2.57 rather than reasoned about;
# tests/parse-sweep/ re-measures the whole set on any bash 3.x host.
#
# …with ONE exception, and it is deliberate: a heredoc still open at end of file is REFUSED. That
# state means the scan stopped at the opener and covered nothing after it, and a guard that has
# quietly stopped looking is worth less than no guard at all — it is the very shape of #131. It is
# also the net that catches a `<<` this scanner mis-read, the way `$(( 1 << 3 ))` was read as a
# heredoc opener until the arithmetic case below was added.
#
# Usage:
#   parse-sweep.sh [-C <repo-path>] [<file>...]
#
# With no <file>, sweeps <repo-path>/tests/*/test.sh.
#
# Exit codes:
#   0  every target parses under this bash, and none carries the command-substitution quote hazard
#   1  REFUSED — a target does not parse, or carries the hazard
#   2  usage / plumbing error — no targets, unreadable path, bad argument. No verdict was reached,
#      so this is NOT a pass; reporting "all clean" over an empty set is the #45 failure exactly.

set -euo pipefail

REPO="."
TARGETS=()

# Print the header block above as the help text, the way scripts/worktrees-ignored.sh and the
# guards in skills/implement-issue/scripts do — a hardcoded line range silently stops documenting
# the exit codes, and ci.yml greps --help for exactly that string.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -C) [ -n "${2:-}" ] || { printf 'parse-sweep: -C needs a <repo-path>\n' >&2; exit 2; }
        REPO="$2"; shift 2 ;;
    -*) printf 'parse-sweep: unexpected argument: %s\n' "$1" >&2; exit 2 ;;
    *)  TARGETS+=("$1"); shift ;;
  esac
done

[ -d "$REPO" ] || { printf 'parse-sweep: %s is not a directory\n' "$REPO" >&2; exit 2; }

if [ ${#TARGETS[@]} -eq 0 ]; then
  [ -d "$REPO/tests" ] || {
    printf 'parse-sweep: no %s/tests directory — refusing to report "all parse" over nothing.\n' \
      "$REPO" >&2; exit 2; }
  for f in "$REPO"/tests/*/test.sh; do
    if [ -f "$f" ]; then TARGETS+=("$f"); fi
  done
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  printf 'parse-sweep: no tests/*/test.sh under %s — refusing to report "all parse" over an\n' \
    "$REPO" >&2
  printf '  empty set. A suite nobody parses looks exactly like a suite that parses (#45).\n' >&2
  exit 2
fi

# ---------------------------------------------------------------------------------- the scanner

# ONE scanner, used for both the shell lines and the heredoc bodies, so the two can never disagree
# about what bash 3.2 considers a quote. Emulates that parser's character scan:
#
#   * outside quotes  — `\` escapes the next character; `'` and `"` open a string; `#` opens a
#                       comment that runs to the newline, but ONLY at the start of the text, after
#                       a newline, or after a blank (see starts_comment)
#   * inside '…'      — nothing is special but the closing `'`. In particular `\` is NOT an escape,
#                       which is precisely why r'…["\']…' re-pairs and #131 happened
#   * inside "…"      — `\` escapes the next character; `"` closes; and `$(` still opens a command
#                       substitution, which is why the state-2 branch below is not just two lines
#
# Sets, in the caller:
#   SC_STATE  0 outside any quote · 1 inside '…' · 2 inside "…"
#   SC_DEPTH  `$(` nesting depth
#   SC_STACK  the quote states suspended by each open `$(`, one digit per level, so closing a
#             substitution restores the string it was opened inside. Persists ACROSS calls (the
#             caller resets it per file) — SC_STATE/SC_DEPTH are re-seeded from the arguments each
#             call, but the suspended states must survive from one line to the next.
#   SC_DELIM  the delimiter of a heredoc opened by this text, or empty
#   SC_DASH   1 when that heredoc used `<<-` (its terminator may be tab-indented)
#   SC_INSUB  1 when that heredoc was opened at `$(` depth > 0 — the hazardous position
#
# $4 = "detect" to look for heredoc openers, anything else to scan quotes only (heredoc bodies are
# not shell, so nothing in them may be read as an opener or as a `$(`).
sweep_scan() {
  local text="$1" i=0 n c nxt prev='' comment=0 detect="${4:-no}" rest ch j pd ac
  SC_STATE="${2:-0}"; SC_DEPTH="${3:-0}"; SC_DELIM=''; SC_DASH=0; SC_INSUB=0
  n=${#text}
  while [ "$i" -lt "$n" ]; do
    c=${text:$i:1}

    if [ "$comment" -eq 1 ]; then
      if [ "$c" = '
' ]; then comment=0; fi
      prev="$c"; i=$((i + 1)); continue
    fi

    if [ "$SC_STATE" -eq 1 ]; then
      if [ "$c" = "'" ]; then SC_STATE=0; fi
      prev="$c"; i=$((i + 1)); continue
    fi

    if [ "$SC_STATE" -eq 2 ]; then
      if [ "$c" = '\' ]; then prev=''; i=$((i + 2)); continue; fi
      # A `$( … )` inside a "…" string is a command substitution like any other — and it is the
      # spelling this kit reaches for most (`PIN="$(python3 - <<'PY'`). Missing it left the scan
      # silent on the #131 line itself whenever it was written that way, and worse: the unmatched
      # quote it then walked past kept the emulator in state 2 for the whole rest of the file, so
      # every later hazard went unseen too.
      if [ "$detect" = detect ] && [ "$c" = '$' ] && [ "${text:$((i + 1)):1}" = '(' ]; then
        sweep_dollar_paren "$text" "$i" "$n"
        i="$SS_I"
        if [ "$SS_OPEN" -eq 1 ]; then
          SC_STACK="$SC_STACK$SC_STATE"; SC_DEPTH=$((SC_DEPTH + 1)); SC_STATE=0; prev='('
        else
          prev=')'
        fi
        continue
      fi
      if [ "$c" = '"' ]; then SC_STATE=0; fi
      prev="$c"; i=$((i + 1)); continue
    fi

    # --- outside any quote
    if [ "$c" = '\' ]; then prev=''; i=$((i + 2)); continue; fi

    if [ "$c" = '#' ] && starts_comment "$prev"; then
      comment=1; prev="$c"; i=$((i + 1)); continue
    fi

    if [ "$c" = "'" ]; then SC_STATE=1; prev="$c"; i=$((i + 1)); continue; fi
    if [ "$c" = '"' ]; then SC_STATE=2; prev="$c"; i=$((i + 1)); continue; fi

    if [ "$detect" = detect ]; then
      nxt=${text:$((i + 1)):1}

      if [ "$c" = '$' ] && [ "$nxt" = '(' ]; then
        sweep_dollar_paren "$text" "$i" "$n"
        i="$SS_I"
        if [ "$SS_OPEN" -eq 1 ]; then
          SC_STACK="$SC_STACK$SC_STATE"; SC_DEPTH=$((SC_DEPTH + 1)); SC_STATE=0; prev='('
        else
          prev=')'
        fi
        continue
      fi

      # `(( … ))` is arithmetic too — same reasoning as sweep_dollar_paren's, without the `$`.
      if [ "$c" = '(' ] && [ "$nxt" = '(' ]; then
        j=$((i + 2)); pd=2
        while [ "$j" -lt "$n" ] && [ "$pd" -gt 0 ]; do
          ac=${text:$j:1}
          if [ "$ac" = '(' ]; then pd=$((pd + 1)); elif [ "$ac" = ')' ]; then pd=$((pd - 1)); fi
          j=$((j + 1))
        done
        prev=')'; i="$j"; continue
      fi

      if [ "$c" = ')' ] && [ "$SC_DEPTH" -gt 0 ]; then
        SC_DEPTH=$((SC_DEPTH - 1))
        SC_STATE=${SC_STACK:$SC_DEPTH:1}; SC_STATE=${SC_STATE:-0}
        SC_STACK=${SC_STACK:0:$SC_DEPTH}
        prev="$c"; i=$((i + 1)); continue
      fi
      if [ "$c" = '<' ] && [ "$nxt" = '<' ]; then
        if [ "${text:$((i + 2)):1}" = '<' ]; then
          prev='<'; i=$((i + 3)); continue      # `<<<` is a herestring, not a heredoc
        fi
        rest=${text:$((i + 2))}
        if [ "${rest:0:1}" = '-' ]; then SC_DASH=1; rest=${rest:1}; fi
        while [ "${rest:0:1}" = ' ' ] || [ "${rest:0:1}" = '	' ]; do rest=${rest:1}; done
        case "$rest" in
          "'"*) rest=${rest#?}; SC_DELIM=${rest%%\'*} ;;
          '"'*) rest=${rest#?}; SC_DELIM=${rest%%\"*} ;;
          *)    SC_DELIM=''
                while [ -n "$rest" ]; do
                  ch=${rest:0:1}
                  case "$ch" in
                    ' '|'	'|';'|'&'|'|'|'('|')'|'<'|'>') break ;;
                  esac
                  SC_DELIM="$SC_DELIM$ch"; rest=${rest:1}
                done ;;
        esac
        if [ "$SC_DEPTH" -gt 0 ]; then SC_INSUB=1; fi
        prev='<'; i=$((i + 2)); continue
      fi
    fi

    prev="$c"; i=$((i + 1))
  done
}

# `$( … )` and `$(( … ))` both begin `$(`, and only the first is a command substitution: `<<` inside
# arithmetic is a left SHIFT, not a heredoc operator. Skipping arithmetic whole is not tidiness —
# measured, `mask=$(( 1 << 3 ))` was read as a heredoc opened with the delimiter `3`, whose
# terminator never arrives, so every remaining line of the file was consumed as body and never
# checked. The fixture that found it genuinely fails on bash 3.2 and the scan called it clean: a
# guard that had gone quiet, which is the failure #131 itself is about. tests/parse-sweep drives it.
#
# Called with the text and the index of the `$`. Sets:
#   SS_I     the index to continue scanning from
#   SS_OPEN  1 when a command substitution was opened (the caller pushes the suspended quote
#            state and takes the depth), 0 when an arithmetic expansion was skipped whole
sweep_dollar_paren() {
  local text="$1" i="$2" n="$3" j pd ac
  if [ "${text:$((i + 2)):1}" = '(' ]; then
    j=$((i + 3)); pd=2
    while [ "$j" -lt "$n" ] && [ "$pd" -gt 0 ]; do
      ac=${text:$j:1}
      if [ "$ac" = '(' ]; then pd=$((pd + 1)); elif [ "$ac" = ')' ]; then pd=$((pd - 1)); fi
      j=$((j + 1))
    done
    SS_I="$j"; SS_OPEN=0
  else
    SS_I=$((i + 2)); SS_OPEN=1
  fi
}

# Inside a command substitution, a `#` opens a comment only at the start of the scanned text, after
# a newline, or after a BLANK. Not after a metacharacter — bash 3.2's scanner concedes the gap in
# its own source ("Not exactly right yet; should handle shell metacharacters") and the difference is
# load-bearing three times over, all measured on 3.2.57:
#
#     print(42)  # it's fine                 parses  — a blank precedes the #
#     x = "a"+"b"#it's glued                 FAILS   — glued to a letter-ish token
#     print("a")#it's glued to a paren       FAILS   — `)` is a metacharacter, and STILL not a
#                                                      comment opener here
#
# That third row is why this is not the lexer's word-boundary rule: `)` ends nearly every Python
# statement, so accepting it as a boundary made the scan silent on the single most likely spelling
# of the hazard.
starts_comment() {
  case "${1:-}" in
    ''|' '|'	'|'
') return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------------- the reporter

hazard_report() {
  local file="$1" line="$2" delim="$3" endstate="$4" count="${5:-1}" quote='"…"' scope=''
  if [ "$endstate" -eq 1 ]; then quote="'…'"; fi
  # With more than one heredoc in the substitution the verdict is about all of them together — they
  # pair with each other, so naming only the first would send a reader to "fix" a body that is
  # innocent on its own. The line is still the first opener: that is where the reading starts.
  if [ "$count" -gt 1 ]; then
    scope="
  $count heredocs share that substitution and are scanned as ONE, because bash never restarts its
  quote scan — the unpaired quote may be in any of them."
  fi
  cat >&2 <<EOF
parse-sweep: REFUSED — $file:$line
  A heredoc (<<$delim) opened INSIDE a \$( … ) command substitution leaves the scan inside a
  $quote string: its quote characters do not pair before the substitution ends.$scope
  bash 3.2 — the /bin/bash macOS still ships — scans a command substitution WITHOUT honouring
  heredoc quoting, so that unpaired quote opens a shell string which never closes, and the WHOLE
  FILE then fails to parse with an "unexpected EOF" pointing at its last line rather than at this
  one. bash 5 parses it happily, so CI alone can never see this (#131).
  fix: spell the offending quote so the embedded language still accepts it but bash's scanner does
       not see a quote — \x27 for the apostrophe, \x22 for the double quote — or move the heredoc
       out of the command substitution.
EOF
}

# ---------------------------------------------------------------------------------- the sweep

BASH_BIN="${BASH:-bash}"
BASH_BANNER=$("$BASH_BIN" --version 2>/dev/null | head -1 || true)
[ -n "$BASH_BANNER" ] || BASH_BANNER="unknown bash at $BASH_BIN"
printf 'parse-sweep: %s\n' "$BASH_BANNER"
printf 'parse-sweep: parser under test: %s\n' "$BASH_BIN"

if [ "${BASH_VERSINFO[0]:-0}" -le 3 ]; then
  printf 'parse-sweep: note — this IS the bash #131 is about, so the `bash -n` half below is\n'
  printf '             meaningful on this host.\n'
else
  printf 'parse-sweep: note — this bash parses the #131 construct happily, so the `bash -n` half\n'
  printf '             below is a NO-OP for it here. The static scan is what carries the guard on\n'
  printf '             this host; a green run here is NOT proof about bash 3.2.\n'
fi

failed=0

for file in "${TARGETS[@]}"; do
  if [ ! -r "$file" ]; then
    printf 'parse-sweep: %s is not readable\n' "$file" >&2
    exit 2
  fi

  # --- half 1: this host's parser has the final say on whether the file can run at all.
  rc=0
  out=$("$BASH_BIN" -n "$file" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    failed=1
    printf 'parse-sweep: REFUSED — %s does not parse under %s\n' "$file" "$BASH_BANNER" >&2
    printf '%s\n' "$out" >&2
    printf '  The reported line is where the parser gave up, which is usually the end of the file\n' >&2
    printf '  rather than the cause. On bash 3.2, suspect a quote inside a heredoc opened within a\n' >&2
    printf '  $( … ) — see #131 and the static scan in this script.\n' >&2
  fi

  # --- half 2: the construct itself, independent of which bash is running.
  #
  # hz_* accumulate ACROSS every heredoc body of the substitution currently open, because that is
  # what bash does: it is hunting for the matching `)` and never restarts its quote scan. Judging a
  # body on its own reported two REFUSALS on a file bash 3.2 parses happily, whose two bodies each
  # left one apostrophe live and paired with EACH OTHER. The verdict therefore lands when the
  # substitution closes, not when a body ends.
  state=0; depth=0; lineno=0
  SC_STACK=''
  delim=''; dash=0; insub=0; open_line=0; body=''
  hz_state=0; hz_line=0; hz_delim=''; hz_count=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [ -n "$delim" ]; then
      probe="$line"
      if [ "$dash" -eq 1 ]; then
        while [ "${probe:0:1}" = '	' ]; do probe=${probe:1}; done
      fi
      if [ "$probe" = "$delim" ]; then
        if [ "$insub" -eq 1 ]; then
          sweep_scan "$body" "$hz_state" 0 no
          hz_state="$SC_STATE"
          hz_count=$((hz_count + 1))
          if [ "$hz_count" -eq 1 ]; then hz_line="$open_line"; hz_delim="$delim"; fi
        fi
        delim=''; dash=0; insub=0; body=''
      else
        body="$body$line
"
      fi
      continue
    fi
    # Two fast paths, each returning exactly what the emulation below would. They exist because
    # these suites are mostly prose — the per-character scan is the whole cost of this script, and
    # a gate slow enough to be skipped locally is the failure this one is meant to fix.
    #   * a line whose first character is `#` is a comment in full, when no string or command
    #     substitution is open across the line break;
    #   * a line holding none of the scanner's characters cannot change the state, the depth, or
    #     open a heredoc.
    if [ "$state" -eq 0 ] && [ "$depth" -eq 0 ]; then
      case "$line" in
        '#'*) continue ;;
        *[\'\"\\#\$\(\)\<]*) : ;;
        *) continue ;;
      esac
    fi

    prev_depth="$depth"
    sweep_scan "$line" "$state" "$depth" detect
    state="$SC_STATE"; depth="$SC_DEPTH"
    if [ -n "$SC_DELIM" ]; then
      delim="$SC_DELIM"; dash="$SC_DASH"; insub="$SC_INSUB"; open_line="$lineno"; body=''
    fi

    # The substitution just closed — now, and only now, are all of its heredoc bodies in. If they
    # leave the scan mid-string, bash 3.2 never sees the `)` this line just wrote.
    if [ "$prev_depth" -gt 0 ] && [ "$depth" -eq 0 ]; then
      if [ "$hz_state" -ne 0 ]; then
        failed=1
        hazard_report "$file" "$hz_line" "$hz_delim" "$hz_state" "$hz_count"
      fi
      hz_state=0; hz_line=0; hz_delim=''; hz_count=0
    fi
  done < "$file"

  # A substitution that never closes leaves its verdict unspoken above, so speak it here. This is
  # the shape the #131 line itself has when it is the last one in the file.
  if [ "$hz_state" -ne 0 ]; then
    failed=1
    hazard_report "$file" "$hz_line" "$hz_delim" "$hz_state" "$hz_count"
  fi

  # A heredoc still open at end of file means the scan STOPPED THERE: everything after the opener
  # was consumed as body and never examined. That is the one outcome a guard must never report as
  # clean, so it is a refusal — and the message says which of the two causes to look for, because
  # the second one is a bug in this script rather than in the file.
  if [ -n "$delim" ]; then
    failed=1
    printf 'parse-sweep: REFUSED — %s: the scan could not complete.\n' "$file" >&2
    printf '  The heredoc <<%s opened at line %s is never terminated, so every line after it was\n' \
      "$delim" "$open_line" >&2
    printf '  read as body and never checked.\n' >&2
    printf '  Either the file really is unterminated — the `bash -n` half above will have said so —\n' >&2
    printf '  or this scanner mis-read a `<<` that is not a heredoc operator, in which case fix the\n' >&2
    printf '  scanner rather than the file. A scan that stops early has to be loud: covering nothing\n' >&2
    printf '  in silence is the failure #131 is about.\n' >&2
  fi
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf 'parse-sweep: %s file(s) parse under this bash; none opens a heredoc inside a $( … ) whose\n' \
  "${#TARGETS[@]}"
printf '             quotes fail to pair.\n'
