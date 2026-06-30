#!/usr/bin/env bash
# Rewrite jeap-admin-ch GitHub links inside Markdown files to index-local,
# repo-prefixed paths so they resolve against the pre-built RAG corpus instead
# of pointing at github.com.
#
# Usage: jeap-rewrite-doc-links.sh <CHECKOUT_DIR>
#
# The set of repositories that are actually indexed is passed via the
# INDEXED_SLUGS environment variable (whitespace-separated slugs). Only links
# whose <repo> segment is in that set are rewritten; links to non-indexed repos
# (e.g. excluded infra repos) are left as their original external URL, since the
# index has no local copy of them. If INDEXED_SLUGS is empty/unset the step is a
# no-op.
#
# Rewrite rules (anchored to the jeap-admin-ch org only; every other https link
# is left intact):
#   1. github.com/jeap-admin-ch/<repo>/blob/(main|master)/<path>           -> <repo>/<path>
#   2. github.com/jeap-admin-ch/<repo>/raw/(main|master)/<path>            -> <repo>/<path>
#   3. github.com/jeap-admin-ch/<repo>/tree/(main|master)/<dir>            -> <repo>/<dir>
#   4. raw.githubusercontent.com/jeap-admin-ch/<repo>/(main|master)/<path> -> <repo>/<path>
#   5. github.com/jeap-admin-ch/<repo> (optional trailing /)               -> <repo>
#
# Only default-branch refs (main/master) are rewritten. The index is a depth-1 clone of each repo's
# default branch, so only that content exists locally. The first path segment after blob/raw/tree
# must be exactly `main` or `master`; it is taken as the ref and everything after it as the in-repo
# path. A ref that does NOT start with main/master -- a tag, a commit SHA, or a slashed branch like
# release/1.0 -- no longer matches, so e.g. .../blob/release/1.0/docs/x.md stays external instead of
# mis-parsing into <repo>/1.0/docs/x.md.
#
# Known, accepted ambiguity: a ref that literally BEGINS with `main/` or `master/` (e.g. a branch or
# tag named `main/next`) is indistinguishable from the default branch followed by a `next/...` path,
# so it is rewritten as if `main` were the ref (.../blob/main/next/docs/x.md -> <repo>/next/docs/x.md).
#
# URL-part handling: a trailing #fragment is PRESERVED (section anchors carry
# over); a ?query string is DROPPED (GitHub view hints are not part of the index
# path). The substitutions only match github.com / raw.githubusercontent.com
# jeap-admin-ch URLs, so an already index-local link does not match and
# re-running is a no-op (idempotent). All *.md / *.markdown files in the checkout
# are processed, including a repo-root README.md.

set -euo pipefail

CHECKOUT_DIR="${1:?CHECKOUT_DIR required}"

log() { printf '[jeap-rewrite-doc-links] %s\n' "$*" >&2; }

if [[ ! -d "$CHECKOUT_DIR" ]]; then
    log "checkout dir '$CHECKOUT_DIR' does not exist - nothing to rewrite"
    exit 0
fi

if [[ -z "${INDEXED_SLUGS:-}" ]]; then
    log "INDEXED_SLUGS is empty/unset - skipping link rewrite in '$CHECKOUT_DIR'"
    exit 0
fi

# Collect Markdown files (NUL-delimited to be safe with odd paths).
mapfile -d '' -t md_files < <(find "$CHECKOUT_DIR" -type f \( -name '*.md' -o -name '*.markdown' \) -print0)

if [[ "${#md_files[@]}" -eq 0 ]]; then
    log "no Markdown files under '$CHECKOUT_DIR'"
    exit 0
fi

# The rewrite is done in Perl: it needs the indexed-slug check inside the
# replacement, fragment-preserve / query-drop tail handling, and a boundary
# lookahead for the bare-repo rule - all awkward in sed. INDEXED_SLUGS reaches
# Perl via the environment. Single-quoted heredoc => no shell interpolation, so
# $1/$& and the literal quote chars in the character classes are preserved.
PERL_REWRITE=$(cat <<'PERL'
BEGIN { our %indexed = map { $_ => 1 } split ' ', ($ENV{INDEXED_SLUGS} // ''); }
# 1+2: github.com .../<repo>/(blob|raw)/(main|master)/<path>  -> <repo>/<path>(+frag,-query)
s{https://github\.com/jeap-admin-ch/([A-Za-z0-9._-]+)/(?:blob|raw)/(?:main|master)/([^\s)>"'\#?]+)(?:\?[^\s)>"'\#]*)?(\#[^\s)>"']*)?}{ $indexed{$1} ? "$1/$2".($3//"") : $& }ge;
# 3: github.com .../<repo>/tree/(main|master)/<dir>  -> <repo>/<dir>(+frag,-query)
s{https://github\.com/jeap-admin-ch/([A-Za-z0-9._-]+)/tree/(?:main|master)/([^\s)>"'\#?]+)(?:\?[^\s)>"'\#]*)?(\#[^\s)>"']*)?}{ $indexed{$1} ? "$1/$2".($3//"") : $& }ge;
# 4: raw.githubusercontent.com/jeap-admin-ch/<repo>/(main|master)/<path>  -> <repo>/<path>(+frag,-query)
s{https://raw\.githubusercontent\.com/jeap-admin-ch/([A-Za-z0-9._-]+)/(?:main|master)/([^\s)>"'\#?]+)(?:\?[^\s)>"'\#]*)?(\#[^\s)>"']*)?}{ $indexed{$1} ? "$1/$2".($3//"") : $& }ge;
# 5: bare repo github.com/jeap-admin-ch/<repo> (opt trailing /) at a URL boundary  -> <repo>(+frag,-query)
#    Like rules 1-4, an optional ?query is consumed and DROPPED and an optional #fragment is PRESERVED,
#    so e.g. github.com/jeap-admin-ch/jeap?tab=readme-ov-file -> jeap (not jeap?tab=readme-ov-file).
s{https://github\.com/jeap-admin-ch/([A-Za-z0-9._-]+)/?(?:\?[^\s)>"'\#]*)?(\#[^\s)>"']*)?(?=[\s)>"']|$)}{ $indexed{$1} ? "$1".($2//"") : $& }ge;
PERL
)

log "rewriting jeap-admin-ch GitHub links in ${#md_files[@]} Markdown file(s) under '$CHECKOUT_DIR'"
perl -i -pe "$PERL_REWRITE" "${md_files[@]}"
