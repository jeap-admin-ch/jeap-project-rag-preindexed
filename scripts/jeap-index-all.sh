#!/usr/bin/env bash
# Index jEAP + JME repositories by dynamically discovering them from their
# public GitHub orgs (jeap-admin-ch, jme-admin-ch), filtering out archived and
# explicitly excluded repos, then delegating to jeap-index.sh once per repo.
# Stops at the first failure.

set -euo pipefail

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"

JEAP_GITHUB_ORG="${JEAP_GITHUB_ORG:-jeap-admin-ch}"
JME_GITHUB_ORG="${JME_GITHUB_ORG:-jme-admin-ch}"
JEAP_GIT_BASE_URL="${JEAP_GIT_BASE_URL:-${GIT_BASE_URL:-https://github.com/${JEAP_GITHUB_ORG}}}"
JME_GIT_BASE_URL="${JME_GIT_BASE_URL:-https://github.com/${JME_GITHUB_ORG}}"
JEAP_INDEX_BIN="${JEAP_INDEX_BIN:-/home/raguser/bin/jeap-index.sh}"

# --- Exclude lists --------------------------------------------------------
# Repos in these lists will NOT be indexed. Archived repos are also skipped
# automatically. Edit these lists to control what gets indexed.

JEAP_EXCLUDE=(
    .github                           # org-level community health/config, no source
    jeap-admin-ch.github.io           # docs site source, not library source
    jeap-central-publishing-maven-plugin  # CI publishing infra
    jeap-license-template             # template/meta
    jeap-project-rag                  # this tooling itself
    jeap-project-rag-preindexed       # this repo
    jeap-python-pipeline-lib          # CI pipeline lib, not application source
    jeap-renovate-presets             # dependency management config
)

JME_EXCLUDE=(
    .github                           # org-level community health/config, no source
    jme-integration-test              # CI integration tests
)

# --- Functions ------------------------------------------------------------

log() { printf '[jeap-index-all] %s\n' "$*" >&2; }

# List all non-archived, public repo names from a GitHub org.
# Usage: list_github_repos <ORG>
# GITHUB_TOKEN, if set, is sent along - raises the otherwise low unauthenticated
# rate limit, and is required at all if the org ever needs non-public access.
list_github_repos() {
    local org="$1"
    local page=1

    while true; do
        local response
        response=$(curl -sf \
            ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
            -H "Accept: application/vnd.github+json" \
            "${GITHUB_API_URL}/orgs/${org}/repos?type=public&per_page=100&page=${page}")

        echo "$response" | jq -r '.[] | select(.archived == false) | .name'

        local count
        count=$(echo "$response" | jq 'length')
        if [[ "$count" -lt 100 ]]; then
            break
        fi
        page=$((page + 1))
    done
}

# Filter a list of repos (one per line on stdin) against an exclude array.
# Usage: echo "repo-list" | filter_excluded EXCLUDE_ARRAY_NAME
filter_excluded() {
    local -n excludes=$1
    while IFS= read -r repo; do
        local excluded=false
        for ex in "${excludes[@]}"; do
            if [[ "$repo" == "$ex" ]]; then
                excluded=true
                break
            fi
        done
        if [[ "$excluded" == "false" ]]; then
            echo "$repo"
        fi
    done
}

index_repos() {
    local git_base_url="$1"
    local flags="$2"
    shift 2
    local repos=("$@")

    for repo in "${repos[@]}"; do
        "$JEAP_INDEX_BIN" $flags "${git_base_url}/${repo}.git" "$repo"
    done
}

# --- Main -----------------------------------------------------------------

log "Discovering JEAP repos from the ${JEAP_GITHUB_ORG} GitHub org..."
mapfile -t JEAP_REPOS < <(list_github_repos "$JEAP_GITHUB_ORG" | filter_excluded JEAP_EXCLUDE | sort)
log "Found ${#JEAP_REPOS[@]} JEAP repos to index"

log "Discovering JME repos from the ${JME_GITHUB_ORG} GitHub org..."
mapfile -t JME_REPOS < <(list_github_repos "$JME_GITHUB_ORG" | filter_excluded JME_EXCLUDE | sort)
log "Found ${#JME_REPOS[@]} JME repos to index"

log "Repos to index:"
log "  [JEAP] (${#JEAP_REPOS[@]} repos, --strip-tests --exclude-docs)"
for repo in "${JEAP_REPOS[@]}"; do log "    - $repo"; done
log "  [JME] (${#JME_REPOS[@]} repos, --exclude-docs)"
for repo in "${JME_REPOS[@]}"; do log "    - $repo"; done

# Whitelist of slugs that are actually indexed. jeap-index.sh -> jeap-rewrite-doc-links.py
# reads this (via the environment) and rewrites only links pointing at an indexed repo,
# leaving links to excluded/non-indexed repos as their original external URL (A1).
export INDEXED_SLUGS="${JEAP_REPOS[*]} ${JME_REPOS[*]}"

# All per-repo passes run with --exclude-docs: the repo-root docs/ subtree is left OUT of the
# per-repo project=<slug> index and instead indexed once below as project=jeap-docs. Without this,
# every docs/ file would be embedded twice (once under <slug>, once under jeap-docs) with identical
# text, so an unfiltered search would return the same chunk twice, halving the useful top-k slots.
# docs/ stays on disk (exclude only shapes the index request), so jeap-stage-docs.sh can still stage
# it. Nested <module>/docs/ trees are NOT excluded (not staged into jeap-docs) and stay per-repo.
index_repos "$JEAP_GIT_BASE_URL" "--strip-tests --exclude-docs" "${JEAP_REPOS[@]}"
index_repos "$JME_GIT_BASE_URL" "--exclude-docs"                "${JME_REPOS[@]}"

# --- Dedicated docs project: stage docs/ subtrees, index once as project=jeap-docs ---
# Each repo above is indexed under project=<slug> with file_path = docs/... (no <repo> segment,
# because the indexed root is /jeap/src/<slug>). jeap-stage-docs.sh stages every */docs subtree
# under a single root (DOCS_CORPUS, default /jeap/docs-corpus) and prints the number of staged repos;
# we then index that corpus ONCE here as project=jeap-docs via jeap-index.sh --no-clone, so its
# file_path carries the <repo>/ segment (<repo>/docs/<topic>.md). The corpus is rooted outside
# /jeap/src, so the final Docker stage (which copies /jeap/src) never ships it. The staging helper
# is idempotent and deletion-safe (guards DOCS_CORPUS); it stages nothing when no docs/ exists
# (-> count 0 -> we skip the pass).
DOCS_CORPUS="${DOCS_CORPUS:-/jeap/docs-corpus}"
DOCS_PROJECT="${DOCS_PROJECT:-jeap-docs}"
STAGE_DOCS_BIN="${STAGE_DOCS_BIN:-$(dirname "$0")/jeap-stage-docs.sh}"

# Hand DOCS_CORPUS to the staging helper so it stages into the
# exact same path the index pass below reads from.
staged_docs_repos="$(DOCS_CORPUS="$DOCS_CORPUS" "$STAGE_DOCS_BIN")"
if [[ "${staged_docs_repos:-0}" -gt 0 ]]; then
    log "Indexing staged docs corpus ($staged_docs_repos repos) as project=$DOCS_PROJECT"
    # No --exclude-docs here: this IS the docs project, so the staged docs/ trees must be indexed.
    "$JEAP_INDEX_BIN" --no-clone "$DOCS_PROJECT" "$DOCS_CORPUS"
else
    log "No docs/ subtrees staged - skipping $DOCS_PROJECT pass"
fi
