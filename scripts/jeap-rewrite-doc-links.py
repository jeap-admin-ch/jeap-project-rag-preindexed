#!/usr/bin/env python3
"""Rewrite jeap-admin-ch GitHub links inside Markdown files to index-local,
repo-prefixed paths so they resolve against the pre-built RAG corpus instead of
pointing at github.com.

Usage: jeap-rewrite-doc-links.py <CHECKOUT_DIR>

The set of repositories that are actually indexed is passed via the
INDEXED_SLUGS environment variable (whitespace-separated slugs). Only links
whose <repo> segment is in that set are rewritten; links to non-indexed repos
(e.g. excluded infra repos) are left as their original external URL, since the
index has no local copy of them. If INDEXED_SLUGS is empty/unset the step is a
no-op.

Rewrite rules (anchored to the jeap-admin-ch org only; every other https link
is left intact):
  1. github.com/jeap-admin-ch/<repo>/blob/(main|master)/<path>           -> <repo>/<path>
  2. github.com/jeap-admin-ch/<repo>/raw/(main|master)/<path>            -> <repo>/<path>
  3. github.com/jeap-admin-ch/<repo>/tree/(main|master)/<dir>            -> <repo>/<dir>
  4. raw.githubusercontent.com/jeap-admin-ch/<repo>/(main|master)/<path> -> <repo>/<path>
  5. github.com/jeap-admin-ch/<repo> (optional trailing /)               -> <repo>

Only default-branch refs (main/master) are rewritten. The index is a depth-1
clone of each repo's default branch, so only that content exists locally. A ref
that does NOT start with main/master -- a tag, a commit SHA, or a slashed branch
like release/1.0 -- does not match, so e.g. .../blob/release/1.0/docs/x.md stays
external instead of mis-parsing into <repo>/1.0/docs/x.md.

Known, accepted ambiguity: a ref that literally BEGINS with `main/` or `master/`
(e.g. a branch/tag named `main/next`) is indistinguishable from the default
branch followed by a `next/...` path, so it is rewritten as if `main` were the
ref (.../blob/main/next/docs/x.md -> <repo>/next/docs/x.md).

URL-part handling: a trailing #fragment is PRESERVED (section anchors carry
over); a ?query string is DROPPED (GitHub view hints are not part of the index
path). The substitutions only match github.com / raw.githubusercontent.com
jeap-admin-ch URLs, so an already index-local link does not match and re-running
is a no-op (idempotent). All *.md / *.markdown files in the checkout are
processed, including a repo-root README.md.
"""

import os
import re
import sys

# Characters that terminate a URL token inside Markdown: whitespace and the
# usual link delimiters ) > " '  (kept in one place so every rule shares it).
_DELIMS = r"""\s)>"'"""
# A repo slug, an in-repo path, an optional ?query (matched then dropped) and an
# optional #fragment (captured then preserved).
_REPO = r"(?P<repo>[A-Za-z0-9._-]+)"
_PATH = rf"(?P<path>[^{_DELIMS}#?]+)"
_QUERY = rf"(?:\?[^{_DELIMS}#]*)?"
_FRAG = rf"(?P<frag>#[^{_DELIMS}]*)?"
_GH = r"https://github\.com/jeap-admin-ch/"
_RAW = r"https://raw\.githubusercontent\.com/jeap-admin-ch/"

# Applied in order; rules 1-4 consume the file/dir URLs first, so the bare-repo
# rule (5) only ever sees true bare-repo links.
_RULES = (
    re.compile(_GH + _REPO + r"/(?:blob|raw)/(?:main|master)/" + _PATH + _QUERY + _FRAG),  # 1+2
    re.compile(_GH + _REPO + r"/tree/(?:main|master)/" + _PATH + _QUERY + _FRAG),          # 3
    re.compile(_RAW + _REPO + r"/(?:main|master)/" + _PATH + _QUERY + _FRAG),              # 4
    # 5: bare repo, optional trailing /, only at a URL boundary (so it never bites
    # into a blob/tree/raw URL whose ref was not main/master).
    re.compile(_GH + _REPO + r"/?" + _QUERY + _FRAG + rf"(?=[{_DELIMS}]|$)", re.MULTILINE),
)


def log(msg):
    print(f"[jeap-rewrite-doc-links] {msg}", file=sys.stderr)


def make_replacer(indexed):
    """Return an re.sub replacement: rewrite to <repo>[/<path>][#frag] when the
    repo is indexed, otherwise leave the original URL untouched."""
    def replace(m):
        repo = m.group("repo")
        if repo not in indexed:
            return m.group(0)
        frag = m.group("frag") or ""
        path = m.groupdict().get("path")
        return f"{repo}/{path}{frag}" if path else f"{repo}{frag}"
    return replace


def rewrite_text(text, replace):
    for rule in _RULES:
        text = rule.sub(replace, text)
    return text


def find_markdown_files(checkout_dir):
    for root, _dirs, files in os.walk(checkout_dir):
        for name in files:
            if name.endswith((".md", ".markdown")):
                p = os.path.join(root, name)
                if not os.path.islink(p):  # match `find -type f`: skip symlinks
                    yield p


def main(argv):
    if len(argv) < 2 or not argv[1]:
        log("CHECKOUT_DIR required")
        return 2
    checkout_dir = argv[1]

    if not os.path.isdir(checkout_dir):
        log(f"checkout dir '{checkout_dir}' does not exist - nothing to rewrite")
        return 0

    indexed = set(os.environ.get("INDEXED_SLUGS", "").split())
    if not indexed:
        log(f"INDEXED_SLUGS is empty/unset - skipping link rewrite in '{checkout_dir}'")
        return 0

    md_files = sorted(find_markdown_files(checkout_dir))
    if not md_files:
        log(f"no Markdown files under '{checkout_dir}'")
        return 0

    log(f"rewriting jeap-admin-ch GitHub links in {len(md_files)} Markdown file(s) "
        f"under '{checkout_dir}'")
    replace = make_replacer(indexed)
    for path in md_files:
        # surrogateescape round-trips any non-UTF-8 bytes unchanged, so a stray
        # non-UTF-8 doc file is edited byte-faithfully (the patterns are ASCII-only).
        with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
            original = f.read()
        rewritten = rewrite_text(original, replace)
        if rewritten != original:
            with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(rewritten)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
