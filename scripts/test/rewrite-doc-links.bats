#!/usr/bin/env bats
# Tests for scripts/jeap-rewrite-doc-links.py (A1): one case per rewrite rule, fragment/query
# handling, scope (only indexed jeap-admin-ch repos), README in scope, and idempotence.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../jeap-rewrite-doc-links.py"
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/repo"
    export INDEXED_SLUGS="jeap-messaging jeap jeap-cli"
}

teardown() {
    rm -rf "$TMP"
}

# Write $1 as the single link line of README.md, run the rewrite, return the rewritten line in $output.
rewrite_line() {
    printf '%s\n' "$1" > "$TMP/repo/README.md"
    run "$SCRIPT" "$TMP"
    [ "$status" -eq 0 ]
    output="$(cat "$TMP/repo/README.md")"
}

@test "blob link with fragment -> index-local path, fragment preserved" {
    rewrite_line "[o](https://github.com/jeap-admin-ch/jeap-messaging/blob/main/docs/outbox.md#configuration)"
    [ "$output" = "[o](jeap-messaging/docs/outbox.md#configuration)" ]
}

@test "blob link with line anchor -> preserved" {
    rewrite_line "[o](https://github.com/jeap-admin-ch/jeap-messaging/blob/main/docs/outbox.md#L12)"
    [ "$output" = "[o](jeap-messaging/docs/outbox.md#L12)" ]
}

@test "blob link on master ref -> index-local path" {
    rewrite_line "[o](https://github.com/jeap-admin-ch/jeap-messaging/blob/master/docs/outbox.md)"
    [ "$output" = "[o](jeap-messaging/docs/outbox.md)" ]
}

@test "blob link with a slashed ref (release/1.0) is left external (not mis-parsed)" {
    rewrite_line "[o](https://github.com/jeap-admin-ch/jeap-messaging/blob/release/1.0/docs/x.md)"
    [ "$output" = "[o](https://github.com/jeap-admin-ch/jeap-messaging/blob/release/1.0/docs/x.md)" ]
}

@test "blob link pinned to a tag/SHA ref is left external" {
    rewrite_line "[o](https://github.com/jeap-admin-ch/jeap-messaging/blob/v1.2.3/docs/x.md)"
    [ "$output" = "[o](https://github.com/jeap-admin-ch/jeap-messaging/blob/v1.2.3/docs/x.md)" ]
}

# Documented, accepted ambiguity: a ref that literally begins with main/ or master/ cannot be told
# apart from the default branch + a path from the URL alone, so it is rewritten as if the ref were
# the default branch. These tests PIN that heuristic so the behavior is intentional and visible.
@test "blob main/next is treated as default branch main (documented heuristic)" {
    rewrite_line "[o](https://github.com/jeap-admin-ch/jeap-messaging/blob/main/next/docs/x.md)"
    [ "$output" = "[o](jeap-messaging/next/docs/x.md)" ]
}

@test "raw main/next is treated as default branch main (documented heuristic)" {
    rewrite_line "[o](https://github.com/jeap-admin-ch/jeap-messaging/raw/main/next/docs/x.md)"
    [ "$output" = "[o](jeap-messaging/next/docs/x.md)" ]
}

@test "tree master/next is treated as default branch master (documented heuristic)" {
    rewrite_line "[o](https://github.com/jeap-admin-ch/jeap-messaging/tree/master/next/docs)"
    [ "$output" = "[o](jeap-messaging/next/docs)" ]
}

@test "raw.githubusercontent main/next is treated as default branch main (documented heuristic)" {
    rewrite_line "[g](https://raw.githubusercontent.com/jeap-admin-ch/jeap/main/next/docs/x.md)"
    [ "$output" = "[g](jeap/next/docs/x.md)" ]
}

@test "blob link with query string -> query dropped" {
    rewrite_line "[x](https://github.com/jeap-admin-ch/jeap-messaging/blob/main/docs/x.md?plain=1)"
    [ "$output" = "[x](jeap-messaging/docs/x.md)" ]
}

@test "blob link with query AND fragment -> query dropped, fragment kept" {
    rewrite_line "<https://github.com/jeap-admin-ch/jeap-messaging/blob/main/docs/x.md?plain=1#L12>"
    [ "$output" = "<jeap-messaging/docs/x.md#L12>" ]
}

@test "raw link -> index-local path" {
    rewrite_line "[r](https://github.com/jeap-admin-ch/jeap-messaging/raw/main/docs/r.md)"
    [ "$output" = "[r](jeap-messaging/docs/r.md)" ]
}

@test "tree (directory) link -> index-local dir" {
    rewrite_line "[d](https://github.com/jeap-admin-ch/jeap-messaging/tree/main/docs)"
    [ "$output" = "[d](jeap-messaging/docs)" ]
}

@test "raw.githubusercontent.com link -> index-local path" {
    rewrite_line "[g](https://raw.githubusercontent.com/jeap-admin-ch/jeap/main/docs/overview/architecture.md)"
    [ "$output" = "[g](jeap/docs/overview/architecture.md)" ]
}

@test "bare repo link -> repo slug" {
    rewrite_line "see https://github.com/jeap-admin-ch/jeap-messaging for details"
    [ "$output" = "see jeap-messaging for details" ]
}

@test "bare repo link with trailing slash -> repo slug" {
    rewrite_line "(https://github.com/jeap-admin-ch/jeap/)"
    [ "$output" = "(jeap)" ]
}

@test "bare repo link with query string -> query dropped" {
    rewrite_line "[j](https://github.com/jeap-admin-ch/jeap?tab=readme-ov-file)"
    [ "$output" = "[j](jeap)" ]
}

@test "bare repo link with fragment -> fragment preserved" {
    rewrite_line "[j](https://github.com/jeap-admin-ch/jeap#readme)"
    [ "$output" = "[j](jeap#readme)" ]
}

@test "bare repo link with query AND fragment -> query dropped, fragment kept" {
    rewrite_line "see https://github.com/jeap-admin-ch/jeap?tab=x#readme here"
    [ "$output" = "see jeap#readme here" ]
}

@test "non-jeap-admin-ch link is left untouched" {
    rewrite_line "[pg](https://www.postgresql.org/docs/index.html)"
    [ "$output" = "[pg](https://www.postgresql.org/docs/index.html)" ]
}

@test "link to an excluded (non-indexed) repo is left untouched" {
    # jeap-aws-pipeline is not in INDEXED_SLUGS
    rewrite_line "[p](https://github.com/jeap-admin-ch/jeap-aws-pipeline/blob/main/docs/x.md)"
    [ "$output" = "[p](https://github.com/jeap-admin-ch/jeap-aws-pipeline/blob/main/docs/x.md)" ]
}

@test "repo-root README.md is rewritten (in scope)" {
    printf '%s\n' "[o](https://github.com/jeap-admin-ch/jeap-messaging/blob/main/README.md)" > "$TMP/repo/README.md"
    run "$SCRIPT" "$TMP"
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/repo/README.md")" = "[o](jeap-messaging/README.md)" ]
}

@test "rewrite is idempotent (running twice == once)" {
    printf '%s\n' "[o](https://github.com/jeap-admin-ch/jeap-messaging/blob/main/docs/outbox.md#config)" > "$TMP/repo/README.md"
    run "$SCRIPT" "$TMP"
    [ "$status" -eq 0 ]
    first="$(cat "$TMP/repo/README.md")"
    run "$SCRIPT" "$TMP"
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/repo/README.md")" = "$first" ]
}

@test "empty INDEXED_SLUGS is a no-op (no rewrite)" {
    export INDEXED_SLUGS=""
    printf '%s\n' "[o](https://github.com/jeap-admin-ch/jeap-messaging/blob/main/docs/outbox.md)" > "$TMP/repo/README.md"
    run "$SCRIPT" "$TMP"
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/repo/README.md")" = "[o](https://github.com/jeap-admin-ch/jeap-messaging/blob/main/docs/outbox.md)" ]
}
