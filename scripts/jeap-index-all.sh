#!/usr/bin/env bash
# Index every jeap repository listed below by delegating to jeap-index.sh
# once per repo. Stops at the first failure.

set -euo pipefail

JEAP_GIT_BASE_URL="${JEAP_GIT_BASE_URL:-${GIT_BASE_URL:-https://bitbucket.bit.admin.ch/scm/jeap}}"
JME_GIT_BASE_URL="${JME_GIT_BASE_URL:-https://bitbucket.bit.admin.ch/scm/bit_jme}"
JEAP_INDEX_BIN="${JEAP_INDEX_BIN:-/home/raguser/bin/jeap-index.sh}"

JEAP_REPOS=(
    jeap-admin-ch
    jeap-internal-spring-boot-parent
    jeap-spring-boot-parent
    jeap-spring-boot-db-migration-starter
    jeap-spring-boot-config-aws-starter
    jeap-spring-boot-tls-starter
    jeap-truststore-maven-plugin
    jeap-reaction-observer
    jeap-crypto
    jeap-spring-boot-roles-anywhere-starter
    jeap-messaging
    jeap-messaging-outbox
    jeap-messaging-sequential-inbox
    jeap-server-sent-events
    jeap-db-schema-publisher
    jeap-open-api-publisher-starter
    jeap-audit
)

JME_REPOS=(
    jme-archive-type-registry
    jme-archrepo-example
    jme-aws-config-example
    jme-aws-db-example
    jme-bptest-example
    jme-cdct-consumer-2-example
    jme-cdct-consumer-example
    jme-cdct-provider-example
    jme-cdct-segregated-consumer-example
    jme-cdct-segregated-provider-example
    jme-crypto-example
    jme-interactiontest-example
    jme-jeap-nivel-oauth-mockserver-scs-template
    jme-jeap-nivel-quadrel-project-template
    jme-jeap-nivel-service-template
    jme-jeap-rhos-oauth-mockserver-scs-template
    jme-jeap-rhos-oblique-project-template
    jme-jeap-rhos-service-template
    jme-message-exchange-client-example
    jme-message-exchange-service-example
    jme-message-type-registry
    jme-messaging-example
    jme-monitor-example
    jme-object-storage-example
    jme-process-archive-example
    jme-process-context-example
    jme-reaction-observer-service
    jme-rhos-config-example
    jme-rhos-db-example
    jme-security-example
    jme-security-oauth2-example
    jme-server-sent-events-example
    jme-swagger-example
)

index_repos() {
    local git_base_url="$1"
    local flags="$2"
    shift 2
    local repos=("$@")

    for repo in "${repos[@]}"; do
        "$JEAP_INDEX_BIN" $flags "${git_base_url}/${repo}.git" "$repo"
    done
}

index_repos "$JEAP_GIT_BASE_URL" "--strip-tests" "${JEAP_REPOS[@]}"
index_repos "$JME_GIT_BASE_URL"  ""              "${JME_REPOS[@]}"
