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
log "  [JEAP] (${#JEAP_REPOS[@]} repos, --strip-tests)"
for repo in "${JEAP_REPOS[@]}"; do log "    - $repo"; done
log "  [JME] (${#JME_REPOS[@]} repos)"
for repo in "${JME_REPOS[@]}"; do log "    - $repo"; done
log "  [GitHub] (${#GITHUB_REPOS[@]} repos, --strip-tests)"
for repo in "${GITHUB_REPOS[@]}"; do log "    - $repo"; done

index_repos "$JEAP_GIT_BASE_URL"   "--strip-tests" "${JEAP_REPOS[@]}"
index_repos "$JME_GIT_BASE_URL"    ""              "${JME_REPOS[@]}"
index_repos "$GITHUB_GIT_BASE_URL" "--strip-tests" "${GITHUB_REPOS[@]}"
