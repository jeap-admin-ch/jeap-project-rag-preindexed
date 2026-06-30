#!/usr/bin/env bash
# Local end-to-end test of the jeap indexing scripts on the host without Docker.
#
# Runs the REAL clone + link-rewrite + docs-staging, with a FAKE project-rag so
# the index step is a no-op (the real binary + model only exist in the base image).
# Inspect the results afterwards under:
#     /jeap/src/<repo>             -> cloned repos with rewritten doc links
#     /jeap/docs-corpus/<repo>/... -> staged docs corpus
#
# The repo scripts are left untouched: they are copied to a temp bin and made
# executable there (the repo's jeap-index.sh is not +x, and index-all execs it).
#
# Prerequisite (one-time): /jeap must exist and be writable by you. The DOCS_CORPUS
# guard in jeap-stage-docs.sh forces the corpus under /jeap/docs-corpus, so the work
# root cannot be relocated:
#     sudo mkdir -p /jeap && sudo chown "$(id -u):$(id -g)" /jeap
#
# Usage:
#   ./local-e2e.sh                 # full discovery: clones ~all JEAP+JME+GitHub repos (slow)
#   SLUGS="jeap-crypto jeap-messaging" ./local-e2e.sh   # test just these JEAP slugs (fast)
set -euo pipefail

# Resolve the repo's scripts/ dir relative to this file (scripts/test/local-e2e.sh -> scripts/).
SCRIPTS_SRC="${SCRIPTS_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# --- /jeap must exist and be writable (DOCS_CORPUS guard forces this path) ---
if [[ ! -d /jeap ]]; then
    echo "Run once:  sudo mkdir -p /jeap && sudo chown \"\$(id -u):\$(id -g)\" /jeap" >&2
    exit 1
fi
if [[ ! -w /jeap ]]; then
    echo "/jeap exists but is not writable by you. Run:  sudo chown \"\$(id -u):\$(id -g)\" /jeap" >&2
    exit 1
fi

# Start clean so you inspect only this run's output.
rm -rf /jeap/src /jeap/docs-corpus

# --- copy scripts to a temp bin and make them executable (keeps the repo pristine) ---
BIN="$(mktemp -d)/bin"
mkdir -p "$BIN"
cp "$SCRIPTS_SRC"/jeap-index.sh \
   "$SCRIPTS_SRC"/jeap-index-all.sh \
   "$SCRIPTS_SRC"/jeap-rewrite-doc-links.py \
   "$SCRIPTS_SRC"/jeap-stage-docs.sh \
   "$BIN/"
chmod +x "$BIN"/*

# --- fake project-rag: logs the JSON-RPC frames it receives, answers id:2, exits on EOF ---
cat > "$BIN/project-rag" <<'FAKE'
#!/usr/bin/env bash
while IFS= read -r line; do
    printf '%s\n' "$line" >> "${FAKE_RAG_LOG:-/jeap/fake-rag.jsonl}"
    case "$line" in
        *'"id":2'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"ok (fake index)"}]}}' ;;
    esac
done
FAKE
chmod +x "$BIN/project-rag"
: > /jeap/fake-rag.jsonl

export PROJECT_RAG_BIN="$BIN/project-rag"
export JEAP_INDEX_BIN="$BIN/jeap-index.sh"
# STAGE_DOCS_BIN and REWRITE_BIN auto-resolve to $BIN (dirname of the scripts), so no overrides needed.

if [[ -n "${SLUGS:-}" ]]; then
    # Fast path: skip Bitbucket discovery, drive jeap-index.sh directly for a few JEAP repos,
    # then stage + (fake-)index docs the same way jeap-index-all.sh does.
    echo ">>> Subset run for: $SLUGS" >&2
    export INDEXED_SLUGS="$SLUGS"
    for slug in $SLUGS; do
        # --exclude-docs mirrors jeap-index-all.sh: docs/ is excluded from the per-repo index and
        # indexed once via the jeap-docs corpus below. docs/ stays on disk, so staging still works.
        "$JEAP_INDEX_BIN" --strip-tests --exclude-docs \
            "https://bitbucket.bit.admin.ch/scm/jeap/${slug}.git" "$slug"
    done
    staged="$(DOCS_CORPUS=/jeap/docs-corpus "$BIN/jeap-stage-docs.sh")"
    if [[ "${staged:-0}" -gt 0 ]]; then
        "$JEAP_INDEX_BIN" --no-clone jeap-docs /jeap/docs-corpus
    fi
else
    # Full faithful run: exactly what CI does (auto-discovery + all repos).
    echo ">>> Full run (auto-discovery, all repos)" >&2
    "$BIN/jeap-index-all.sh"
fi

echo
echo "=== Done. Inspect: ==="
echo "  Cloned + rewritten repos : /jeap/src/"
echo "  Staged docs corpus       : /jeap/docs-corpus/"
echo "  Fake indexer JSON-RPC log: /jeap/fake-rag.jsonl"
