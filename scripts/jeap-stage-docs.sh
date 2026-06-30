#!/usr/bin/env bash
# Stage every <SRC_ROOT>/*/docs subtree into a single corpus root so it can be indexed once as a
# dedicated documentation project (Variant 3). Rooting the corpus at /jeap/docs-corpus makes the
# indexed file_path carry the <repo>/ segment (<repo>/docs/<topic>.md), giving a clean, corpus-wide
# docs project. Invoked from jeap-index-all.sh after the per-repo passes.
#
# Configurable via the environment:
#   SRC_ROOT     (default /jeap/src)            - where the cloned repos live
#   DOCS_CORPUS  (default /jeap/docs-corpus)    - staging root (must be /jeap/docs-corpus or a subpath)
#
# The validate/stage logic is split into functions and main() only runs when the script is executed
# (not when sourced), so the guard and the staging loop are independently unit-testable.

set -euo pipefail

SRC_ROOT="${SRC_ROOT:-/jeap/src}"
DOCS_CORPUS="${DOCS_CORPUS:-/jeap/docs-corpus}"

log() { printf '[jeap-stage-docs] %s\n' "$*" >&2; }

# Guard for the rm -rf in stage_docs. DOCS_CORPUS is env-overridable, allow ONLY
# /jeap/docs-corpus or a real subpath of it, and reject any '..' segment.
validate_docs_corpus() {
    local corpus="$1"
    case "$corpus" in
        *..*) log "Refusing DOCS_CORPUS='$corpus' (contains '..')"; return 1 ;;
        /jeap/docs-corpus|/jeap/docs-corpus/*) return 0 ;;
        *) log "Refusing DOCS_CORPUS='$corpus' (must be /jeap/docs-corpus or a subpath)"; return 1 ;;
    esac
}

# Stage every <src_root>/*/docs subtree into <corpus>/<repo>/docs and print the number of staged
# repos on stdout. Cleans the corpus first (idempotent: stale/renamed/deleted docs do not linger)
# and copies directory CONTENTS, not the dir, to avoid docs/docs nesting on re-run. Assumes the
# corpus path was already validated by the caller; keeps only a minimal /-and-empty sanity check.
# Symlinks are not staged: a symlinked top-level docs dir is skipped, and any symlink found INSIDE a
# staged docs tree is removed, so only real in-repo files reach the index (project-rag follows
# symlinks on read, so a symlink could otherwise leak content from outside the checkout).
stage_docs() {
    local src_root="$1" corpus="$2"
    [[ -n "$corpus" && "$corpus" != "/" ]] || { log "refusing to stage into corpus='$corpus'"; return 1; }
    rm -rf "$corpus"
    shopt -s nullglob
    local staged=0 docs_dir repo
    for docs_dir in "$src_root"/*/docs; do
        # Skip a symlinked top-level docs dir: cp "$docs_dir/." dereferences the symlink and copies
        # the TARGET's contents, so a repo that commits `docs` as a symlink (to an absolute path or
        # ../.. outside its checkout) could pull arbitrary readable files into the corpus and the
        # index. Only stage real in-repo docs subtrees.
        if [[ -L "$docs_dir" ]]; then
            log "skipping symlinked docs dir $docs_dir (refusing to follow it outside the checkout)"
            continue
        fi
        [ -d "$docs_dir" ] || continue
        repo="$(basename "$(dirname "$docs_dir")")"
        mkdir -p "$corpus/$repo/docs"
        cp -a "$docs_dir/." "$corpus/$repo/docs/"
        # cp -a PRESERVES symlinks (it is --no-dereference), and project-rag reads indexed files
        # through symlink-following fs calls (fs::metadata / fs::read_to_string), so a symlinked file
        # committed INSIDE a real docs/ (e.g. docs/secret.md -> /etc/passwd or ../../outside) would
        # otherwise leak content from outside the checkout into the jeap-docs index. The corpus is a
        # throwaway staging copy, so drop every staged symlink (file or dir); only real, in-repo
        # files get indexed.
        local -a links
        mapfile -d '' -t links < <(find "$corpus/$repo/docs" -type l -print0)
        if (( ${#links[@]} > 0 )); then
            log "removing ${#links[@]} symlink(s) from staged docs for '$repo' (refusing to index outside the checkout)"
            find "$corpus/$repo/docs" -type l -delete
        fi
        staged=$((staged+1))
    done
    printf '%s\n' "$staged"
}

main() {
    validate_docs_corpus "$DOCS_CORPUS" || exit 1
    local staged
    staged="$(stage_docs "$SRC_ROOT" "$DOCS_CORPUS")"
    if [ "$staged" -gt 0 ]; then
        log "Staged docs corpus ($staged repos) at $DOCS_CORPUS"
    else
        log "No docs/ subtrees found under $SRC_ROOT - nothing staged"   # robust to 'docs partially present'
    fi
    # Emit the staged-repo count for the caller; it decides whether to run the jeap-docs index pass.
    printf '%s\n' "$staged"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
