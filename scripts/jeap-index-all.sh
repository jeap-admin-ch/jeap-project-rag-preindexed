#!/usr/bin/env bash
# Index every jeap repository listed below by delegating to jeap-index.sh
# once per repo. Stops at the first failure.

set -euo pipefail

GIT_BASE_URL="${GIT_BASE_URL:-https://bitbucket.bit.admin.ch/scm/jeap}"
JEAP_INDEX_BIN="${JEAP_INDEX_BIN:-/usr/local/bin/jeap-index.sh}"

REPOS=(
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

for repo in "${REPOS[@]}"; do
    "$JEAP_INDEX_BIN" "${GIT_BASE_URL}/${repo}.git" "$repo"
done
