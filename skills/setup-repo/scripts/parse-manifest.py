#!/usr/bin/env python3
"""parse-manifest.py — read a repo-setup manifest and emit one flat record per desired item.

Why this is a file and not a `python3 -c` inside repo-setup.sh. macOS still ships bash 3.2, and
its command-substitution scanner does not honour heredoc quoting: every quote in the body of a
heredoc opened inside `$( … )` is read as a shell quote, and an unpaired one runs the scanner to
end-of-file. That is #131, and `scripts/parse-sweep.sh` exists to catch it. A separate file has no
quoting relationship with its caller at all, so the hazard cannot arise — and the parser becomes
independently runnable, which is how tests/repo-setup asserts the shipped manifest declares the
three axes.

Output is tab-separated, one record per line, because tab is already the kit's internal field
separator (requirements.json says so, and forbids tabs in values for exactly this reason):

    L <TAB> name <TAB> color <TAB> description      a label
    T <TAB> filename                                an issue-form file
    S <TAB> key <TAB> value                         a repository setting
    K <TAB> glob                                    a label --prune must never delete

Colours are normalised (leading '#' dropped, lower-cased) so that `d93f0b`, `#d93f0b` and
`#D93F0B` cannot read as three different desired states and produce a permanent ~EDIT that never
converges. Booleans are normalised to `true`/`false` for the same reason: PyYAML gives Python
`True`, `gh api` speaks JSON, and `str(True)` is `"True"`, which matches neither.

Exit codes:
  0  parsed
  2  unreadable or not valid YAML, or not a mapping (the caller turns this into its own exit 2)
"""
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit("PyYAML is required by repo-setup.sh — install it (pip install PyYAML)")


def die(message):
    sys.stderr.write("ERR: %s\n" % message)
    raise SystemExit(2)


def norm_scalar(value):
    """A YAML scalar as the string `gh` would compare against."""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return ""
    return str(value).strip()


def main(argv):
    if len(argv) != 2:
        die("usage: parse-manifest.py <manifest.yml>")
    path = argv[1]

    try:
        with open(path, encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
    except OSError:
        die("cannot read the manifest '%s'" % path)
    except yaml.YAMLError as exc:
        die("the manifest '%s' is not valid YAML (%s)" % (path, exc.__class__.__name__))

    if data is None:
        data = {}
    if not isinstance(data, dict):
        die("the manifest '%s' must be a YAML mapping, got %s" % (path, type(data).__name__))

    out = []

    for entry in data.get("labels") or []:
        if not isinstance(entry, dict):
            die("every labels[] entry must be a mapping, got %s" % type(entry).__name__)
        name = norm_scalar(entry.get("name"))
        if not name:
            die("a labels[] entry has no name")
        if "\t" in name:
            die("label name %r contains a tab, which is this format's field separator" % name)
        color = norm_scalar(entry.get("color")).lstrip("#").lower()
        out.append("L\t%s\t%s\t%s" % (name, color, norm_scalar(entry.get("description"))))

    for entry in data.get("issueTemplates") or []:
        name = norm_scalar(entry)
        if not name:
            continue
        if "/" in name or name.startswith("."):
            die("issueTemplates[] takes a bare file name, got %r" % name)
        out.append("T\t%s" % name)

    for entry in data.get("pruneKeep") or []:
        pattern = norm_scalar(entry)
        if pattern:
            out.append("K\t%s" % pattern)

    settings = data.get("settings") or {}
    if not isinstance(settings, dict):
        die("settings must be a mapping, got %s" % type(settings).__name__)
    # Sorted so the emitted plan is stable run to run: an unstable order would make a converged
    # repo's report differ between runs, and a diff that changes on its own teaches nothing.
    for key in sorted(settings):
        out.append("S\t%s\t%s" % (key, norm_scalar(settings[key])))

    if out:
        # Newlines are pinned to LF rather than left to `print`. On Windows, text-mode stdout
        # translates "\n" to "\r\n", and the caller splits these records on TAB — so the CR lands
        # inside the LAST FIELD of every record. Measured: a label description came back as
        # "Pull this first\r", which never equals what `gh` reports, so every label read as ~EDIT
        # and `apply` rewrote all of them on every run. Silent, idempotence-breaking, and invisible
        # on the Linux CI that would have to catch it (#174 is the same platform gap one layer up).
        # The ENCODING is pinned for the same reason and was the half this call originally left to
        # the locale. A Windows console is cp1252, so an em-dash in a description left as the
        # single byte 0x97 — invalid UTF-8 — `gh` sent that, and the label was created with a
        # description that can never equal what the manifest asks for. Measured 2026-08-20: ten
        # labels applied corrupted here, each reported ~EDIT by every later `plan`, so `apply`
        # rewrote all ten every run and converged on none (#196). This is the manifest's own text
        # reaching GitHub intact, not a display concern.
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")
        sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
