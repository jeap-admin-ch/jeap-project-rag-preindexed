#!/usr/bin/env bash
# Index jEAP repositories by dynamically discovering them from Bitbucket,
# filtering out archived and explicitly excluded repos, then delegating to
# jeap-index.sh once per repo. GitHub repos use a static list.
# Stops at the first failure.

set -euo pipefail

BITBUCKET_BASE_URL="${BITBUCKET_BASE_URL:-https://bitbucket.bit.admin.ch}"

JEAP_GIT_BASE_URL="${JEAP_GIT_BASE_URL:-${GIT_BASE_URL:-${BITBUCKET_BASE_URL}/scm/jeap}}"
JME_GIT_BASE_URL="${JME_GIT_BASE_URL:-${BITBUCKET_BASE_URL}/scm/bit_jme}"
GITHUB_GIT_BASE_URL="${GITHUB_GIT_BASE_URL:-https://github.com/jeap-admin-ch}"
JEAP_INDEX_BIN="${JEAP_INDEX_BIN:-/home/raguser/bin/jeap-index.sh}"

# --- Exclude lists --------------------------------------------------------
# Repos in these lists will NOT be indexed. Archived repos are also skipped
# automatically. Edit these lists to control what gets indexed.

JEAP_EXCLUDE=(
    aws-codebuild-amazonlinux2        # Legacy CI build image
    jeap                              # Legacy jEAP
    jeap-admin-ch                     # indexed from GitHub (jeap umbrella repo with docs)
    jeap-aws-pipeline                 # CI pipeline infra
    jeap-central-publishing-maven-plugin  # CI publishing infra
    jeap-cli                          # indexed from GitHub
    jeap-keycloak-pams                # infrastructure
    jeap-libraries-trivy-scan         # CI security scanning
    jeap-license-template             # template/meta
    jeap-microservice-pipeline        # Legacy CI pipeline
    jeap-migration-bot                # internal tool
    jeap-pact-webhook                 # CI infra
    jeap-pipelinelibrary              # Legacy CI pipeline
    jeap-pipeline-seed                # CI pipeline seed job
    jeap-project-rag                  # this tooling itself
    jeap-project-rag-preindexed       # this repo
    jeap-python-pipeline-lib          # Internal CI pipeline lib
    jeap-renovate-config              # dependency management config
    jeap-renovate-presets             # dependency management config
    jeap-trivyignore                  # security config
    jeap-version-overview             # version overview repo, will be provided as dedicated MCP tool
)

JME_EXCLUDE=(
    jme-certificates                  # infrastructure/certs
    jme-examples-trivy-scan           # CI security scanning
    jme-integration-test              # CI integration tests
    jme-keycloak-introspection-performance-test  # performance test
    jme-mes-performance-tests         # performance test
    jme-messaging-performance-tests   # performance test
    jme-renovate-image-test           # CI/renovate testing
)

# Public OSS jEAP repos on GitHub (static list, no API discovery).
GITHUB_REPOS=(
    jeap-cli
    jeap
)

# --- Functions ------------------------------------------------------------

log() { printf '[jeap-index-all] %s\n' "$*" >&2; }

# List all non-archived repo slugs from a Bitbucket project.
# Usage: list_bitbucket_repos <PROJECT_KEY>
list_bitbucket_repos() {
    local project_key="$1"
    local start=0

    while true; do
        local response
        response=$(curl -sf \
            "${BITBUCKET_BASE_URL}/rest/api/1.0/projects/${project_key}/repos?limit=100&start=${start}")

        echo "$response" | jq -r '.values[] | select(.archived == false) | .slug'

        local is_last_page
        is_last_page=$(echo "$response" | jq -r '.isLastPage')
        if [[ "$is_last_page" == "true" ]]; then
            break
        fi
        start=$(echo "$response" | jq -r '.nextPageStart')
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

log "Discovering JEAP repos from Bitbucket project JEAP..."
mapfile -t JEAP_REPOS < <(list_bitbucket_repos "JEAP" | filter_excluded JEAP_EXCLUDE | sort)
log "Found ${#JEAP_REPOS[@]} JEAP repos to index"

log "Discovering JME repos from Bitbucket project BIT_JME..."
mapfile -t JME_REPOS < <(list_bitbucket_repos "BIT_JME" | filter_excluded JME_EXCLUDE | sort)
log "Found ${#JME_REPOS[@]} JME repos to index"

log "Repos to index:"
log "  [JEAP] (${#JEAP_REPOS[@]} repos, --strip-tests --exclude-docs)"
for repo in "${JEAP_REPOS[@]}"; do log "    - $repo"; done
log "  [JME] (${#JME_REPOS[@]} repos, --exclude-docs)"
for repo in "${JME_REPOS[@]}"; do log "    - $repo"; done
log "  [GitHub] (${#GITHUB_REPOS[@]} repos, --strip-tests --exclude-docs)"
for repo in "${GITHUB_REPOS[@]}"; do log "    - $repo"; done

# Whitelist of slugs that are actually indexed. jeap-index.sh -> jeap-rewrite-doc-links.sh
# reads this (via the environment) and rewrites only links pointing at an indexed repo,
# leaving links to excluded/non-indexed repos as their original external URL (A1).
export INDEXED_SLUGS="${JEAP_REPOS[*]} ${JME_REPOS[*]} ${GITHUB_REPOS[*]}"

# All per-repo passes run with --exclude-docs: the repo-root docs/ subtree is left OUT of the
# per-repo project=<slug> index and instead indexed once below as project=jeap-docs. Without this,
# every docs/ file would be embedded twice (once under <slug>, once under jeap-docs) with identical
# text, so an unfiltered search would return the same chunk twice, halving the useful top-k slots.
# docs/ stays on disk (exclude only shapes the index request), so jeap-stage-docs.sh can still stage
# it. Nested <module>/docs/ trees are NOT excluded (not staged into jeap-docs) and stay per-repo.
index_repos "$JEAP_GIT_BASE_URL"   "--strip-tests --exclude-docs" "${JEAP_REPOS[@]}"
index_repos "$JME_GIT_BASE_URL"    "--exclude-docs"               "${JME_REPOS[@]}"
index_repos "$GITHUB_GIT_BASE_URL" "--strip-tests --exclude-docs" "${GITHUB_REPOS[@]}"

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
