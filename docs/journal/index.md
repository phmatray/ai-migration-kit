---
title: Journal
nav_order: 9
has_children: true
---

# Journal

One article per published release, oldest first. `CHANGELOG.md` answers *what changed if I update?*;
this answers *why did we do that, and what did we learn?* Walk it front to back and the kit's
evolution reads as a story rather than a diff.

Two prose rules, enforced by `tests/skills/test.sh` rather than by review: every article is in
English, and no article contains an em dash. Use commas, colons, parentheses or separate sentences
instead. French quoted inside guillemets does not count against the first rule, so an article can
still quote what a skill actually says.

## Adding the next article

When a release lands:

1. Copy the newest article to `docs/journal/v<the new version>.md`.
2. Set `nav_order` to the previous article's plus one. Never renumber an existing article.
3. Rewrite the body from `gh release view v<the new version>` and
   `git log v<previous>..v<the new version> --oneline`, in the voice of whoever shipped it: what the
   release was answering, what was decided, what got cut, what bit us.
4. Run `./tests/skills/test.sh`.

The guard checks what is here, not what is missing: it holds every article to the two prose rules and
to a unique `nav_order`, and it does not yet know which releases have no article at all.
