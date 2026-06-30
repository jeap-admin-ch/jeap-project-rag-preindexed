#!/usr/bin/env bash
# Index a single repo into project-rag's LanceDB by driving its MCP server
# over stdio. Designed to be invoked once per repo from the Dockerfile.
#
# Usage:
#   jeap-index.sh [--strip-tests] [--exclude-docs] <REPO_URL> <PROJECT_NAME> [CHECKOUT_DIR]
#   jeap-index.sh --no-clone [--strip-tests] [--exclude-docs] <PROJECT_NAME> <CHECKOUT_DIR>
#
# The flags are orthogonal
#   --no-clone      skip the clone (and the REPO_URL positional); CHECKOUT_DIR must already exist.
#   --strip-tests   delete src/test trees from CHECKOUT_DIR before indexing.
#   --exclude-docs  exclude the repo-root docs/ subtree from THIS index (via index_codebase
#                   exclude_patterns). The docs/ files stay on disk; documentation is indexed once in
#                   the dedicated jeap-docs corpus instead, so the same doc chunk is not returned
#                   twice in an unfiltered search.
#
# The run is three independent steps: (1) obtain the tree (clone, or verify the CHECKOUT_DIR for
# --no-clone), (2) strip src/test if --strip-tests was given, (3) rewrite jeap-admin-ch doc links in
# place (a no-op when INDEXED_SLUGS is empty). --exclude-docs then only shapes the index request.

set -euo pipefail

STRIP_TESTS=0
NO_CLONE=0
EXCLUDE_DOCS=0
# Consume leading flags.
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --strip-tests)  STRIP_TESTS=1; shift ;;
        --no-clone)     NO_CLONE=1; shift ;;
        --exclude-docs) EXCLUDE_DOCS=1; shift ;;
        --)             shift; break ;;
        *)              printf '[jeap-index] unknown flag: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [[ "$NO_CLONE" == "1" ]]; then
    # No REPO_URL positional in --no-clone mode; CHECKOUT_DIR is required.
    PROJECT_NAME="${1:?PROJECT_NAME required}"
    CHECKOUT_DIR="${2:?CHECKOUT_DIR required (mandatory in --no-clone mode)}"
else
    REPO_URL="${1:?REPO_URL required}"
    PROJECT_NAME="${2:?PROJECT_NAME required}"
    CHECKOUT_DIR="${3:-/jeap/src/${PROJECT_NAME}}"
fi

PROJECT_RAG_BIN="${PROJECT_RAG_BIN:-/usr/local/bin/project-rag}"
REWRITE_BIN="${REWRITE_BIN:-$(dirname "$0")/jeap-rewrite-doc-links.sh}"

log() { printf '[jeap-index] %s\n' "$*" >&2; }

# Step 1: obtain the tree. --no-clone skips the clone and only verifies the checkout dir exists;
# otherwise we clone it fresh.
if [[ "$NO_CLONE" == "1" ]]; then
    log "--no-clone: using already-staged tree ${CHECKOUT_DIR} as project=${PROJECT_NAME}"
    [[ -d "$CHECKOUT_DIR" ]] || { log "checkout dir ${CHECKOUT_DIR} does not exist"; exit 1; }
else
    log "cloning ${REPO_URL} -> ${CHECKOUT_DIR}"
    mkdir -p "$(dirname "$CHECKOUT_DIR")"
    git clone --depth 1 "$REPO_URL" "$CHECKOUT_DIR"
fi

# Step 2: strip src/test if requested.
if [[ "$STRIP_TESTS" == "1" ]]; then
    log "stripping src/test directories from ${CHECKOUT_DIR}"
    find "$CHECKOUT_DIR" -type d -path '*/src/test' -prune -exec rm -rf {} +
fi

# Remove common files that add noise to the index (legal, CI, build wrappers, etc.)
log "removing non-indexable files from ${CHECKOUT_DIR}"
for name in AGENTS.md CHANGELOG.md CONTRIBUTING.md SECURITY.md THIRD-PARTY-LICENSES.md \
            LICENSE Jenkinsfile publiccode.yml setPomVersions.sh mvnw mvnw.cmd; do
    find "$CHECKOUT_DIR" -maxdepth 1 -name "$name" -delete
done
find "$CHECKOUT_DIR" -maxdepth 1 -type d -name '.mvn' -exec rm -rf {} +

# Step 2b: drop symlinks before indexing. project-rag reads indexed files through symlink-following
# fs calls (fs::metadata / fs::read_to_string), so a symlink committed anywhere in the tree whose
# target escapes the checkout (e.g. -> /etc/passwd or ../../..) could leak readable build-container
# files into the index. We only ever want to index real, in-tree files, so remove every symlink
# (file or dir) from CHECKOUT_DIR. This guards the per-repo clones, and under --no-clone is a second
# line of defence for the jeap-docs corpus.
mapfile -d '' -t _symlinks < <(find "$CHECKOUT_DIR" -type l -print0)
if (( ${#_symlinks[@]} > 0 )); then
    log "removing ${#_symlinks[@]} symlink(s) from ${CHECKOUT_DIR} before indexing (refusing to index outside the checkout)"
    find "$CHECKOUT_DIR" -type l -delete
fi

# Step 3: rewrite jeap-admin-ch GitHub links in Markdown to index-local paths BEFORE indexing, so
# the embedded chunk text carries the index-local links (A1). The helper itself no-ops when
# INDEXED_SLUGS is unset, it is safe to run on an already-rewritten corpus (the rewrite is idempotent).
if [[ -x "$REWRITE_BIN" ]]; then
    "$REWRITE_BIN" "$CHECKOUT_DIR"
else
    log "link-rewrite helper not found/executable at ${REWRITE_BIN} - skipping link rewrite"
fi

log "starting project-rag MCP server"
coproc RAG { "$PROJECT_RAG_BIN"; }
# Bash AUTO-UNSETS the coproc's $RAG_PID (and the $RAG fd array) the moment it reaps the coprocess,
# which can happen asynchronously as soon as the server exits. Capture the PID into our own variable
# now so teardown never references the bash-managed $RAG_PID after it has been unset -- otherwise a
# reap that races ahead of the wait below would abort the script via `set -u` (unbound variable) even
# though indexing succeeded. Our copy is never auto-unset, so the teardown is deterministic.
# shellcheck disable=SC2153  # $RAG_PID is defined by `coproc RAG` above; it is not a typo of rag_pid.
rag_pid=$RAG_PID

cleanup() {
    if [[ -n "${rag_pid:-}" ]] && kill -0 "$rag_pid" 2>/dev/null; then
        kill "$rag_pid" 2>/dev/null || true
        wait "$rag_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# JSON-RPC frames. The init/initialized frames are static. The index frame embeds CHECKOUT_DIR and
# PROJECT_NAME, which under --no-clone can come from DOCS_CORPUS/DOCS_PROJECT env overrides, so build
# it with `jq --arg` to guarantee valid JSON escaping for any quotes/backslashes/newlines in those
# values. jq is installed in the indexer image.
#
# With --exclude-docs we add an exclude_patterns entry so the repo-root docs/ subtree is left OUT of
# this per-repo index (documentation is indexed once under jeap-docs instead). IMPORTANT: despite the
# tool schema describing exclude_patterns as glob syntax, project-rag matches each pattern as a plain
# SUBSTRING of the file's ABSOLUTE path. We therefore pass the absolute prefix "$CHECKOUT_DIR/docs/":
# it matches the top-level docs/ subtree but is NOT a substring of a nested "$CHECKOUT_DIR/<mod>/docs/",
# so nested module docs stay in the per-repo index (only top-level */docs is staged into jeap-docs).
req_init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"jeap-index","version":"1.0.0"}}}'
req_initialized='{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
req_index=$(jq -cn \
    --arg path "$CHECKOUT_DIR" \
    --arg project "$PROJECT_NAME" \
    --arg docs_prefix "$CHECKOUT_DIR/docs/" \
    --argjson exclude_docs "$EXCLUDE_DOCS" \
    '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"index_codebase",
      arguments:( {path:$path,project:$project}
                  + (if $exclude_docs == 1 then {exclude_patterns:[$docs_prefix]} else {} end) )}}')

log "sending initialize + index_codebase for project=${PROJECT_NAME}"
printf '%s\n%s\n%s\n' "$req_init" "$req_initialized" "$req_index" >&"${RAG[1]}"

# Read responses until id=2 arrives. Indexing can take minutes, so no timeout.
status=0
while IFS= read -r line <&"${RAG[0]}"; do
    printf '[mcp] %s\n' "$line" >&2
    if [[ "$line" == *'"id":2'* ]]; then
        if [[ "$line" == *'"error"'* ]] || [[ "$line" == *'"isError":true'* ]]; then
            log "indexing failed for ${PROJECT_NAME}"
            status=1
        else
            log "indexing succeeded for ${PROJECT_NAME}"
        fi
        break
    fi
done

# Close stdin so the server exits cleanly, then wait on our captured PID (bash may already have
# reaped the coproc and unset $RAG_PID/$RAG by now; wait on a reaped PID just no-ops via || true).
exec {RAG[1]}>&-
wait "$rag_pid" 2>/dev/null || true
rag_pid=

exit "$status"
