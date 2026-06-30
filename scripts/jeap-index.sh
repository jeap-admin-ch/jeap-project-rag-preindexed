#!/usr/bin/env bash
# Index a single repo into project-rag's LanceDB by driving its MCP server
# over stdio. Designed to be invoked once per repo from the Dockerfile.
#
# Usage: jeap-index.sh [--strip-tests] <REPO_URL> <PROJECT_NAME> [CHECKOUT_DIR]

set -euo pipefail

STRIP_TESTS=0
if [[ "${1:-}" == "--strip-tests" ]]; then
    STRIP_TESTS=1
    shift
fi

REPO_URL="${1:?REPO_URL required}"
PROJECT_NAME="${2:?PROJECT_NAME required}"
CHECKOUT_DIR="${3:-/jeap/src/${PROJECT_NAME}}"

PROJECT_RAG_BIN="${PROJECT_RAG_BIN:-/usr/local/bin/project-rag}"

log() { printf '[jeap-index] %s\n' "$*" >&2; }

log "cloning ${REPO_URL} -> ${CHECKOUT_DIR}"
mkdir -p "$(dirname "$CHECKOUT_DIR")"
git clone --depth 1 "$REPO_URL" "$CHECKOUT_DIR"

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

log "starting project-rag MCP server"
coproc RAG { "$PROJECT_RAG_BIN"; }

cleanup() {
    if [[ -n "${RAG_PID:-}" ]] && kill -0 "$RAG_PID" 2>/dev/null; then
        kill "$RAG_PID" 2>/dev/null || true
        wait "$RAG_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# JSON-RPC frames. We embed the path/project via printf %s to avoid quoting
# issues; both values are controlled inputs (Dockerfile args), not user data.
req_init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"jeap-index","version":"1.0.0"}}}'
req_initialized='{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
req_index=$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"index_codebase","arguments":{"path":"%s","project":"%s"}}}' \
    "$CHECKOUT_DIR" "$PROJECT_NAME")

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

# Close stdin so the server exits cleanly.
exec {RAG[1]}>&-
wait "$RAG_PID" 2>/dev/null || true
RAG_PID=

exit "$status"
