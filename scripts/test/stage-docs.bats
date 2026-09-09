#!/usr/bin/env bats
# Tests for scripts/jeap-stage-docs.sh: the DOCS_CORPUS guard (must refuse dangerous explicit paths
# without running rm -rf) and the staging loop (idempotent, no docs/docs nesting, deleted docs
# disappear). The script only STAGES and prints the staged-repo count on stdout; the index_codebase
# call lives in jeap-index-all.sh, so main() must never invoke an indexer.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../jeap-stage-docs.sh"
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/bin"
    # Fake rm: log invocations instead of deleting, so a guard regression that reaches rm -rf is
    # caught before it can delete anything.
    cat > "$TMP/bin/rm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/rm.log"
EOF
    chmod +x "$TMP/bin/rm"
    # Source the script to unit-test its functions; main() only runs when executed, not sourced.
    # shellcheck source=/dev/null
    source "$SCRIPT"
    set +euo pipefail   # keep bats test body lenient; the functions don't depend on errexit
}

teardown() {
    rm -rf "$TMP"
}

# --- guard (pure function) ---

@test "validate accepts /jeap/docs-corpus" {
    run validate_docs_corpus "/jeap/docs-corpus"
    [ "$status" -eq 0 ]
}

@test "validate accepts a subpath of /jeap/docs-corpus" {
    run validate_docs_corpus "/jeap/docs-corpus/sub"
    [ "$status" -eq 0 ]
}

@test "validate rejects /jeap/src" {
    run validate_docs_corpus "/jeap/src"
    [ "$status" -ne 0 ]
}

@test "validate rejects /jeap" {
    run validate_docs_corpus "/jeap"
    [ "$status" -ne 0 ]
}

@test "validate rejects /" {
    run validate_docs_corpus "/"
    [ "$status" -ne 0 ]
}

@test "validate rejects /jeap/docs-corpus/.. (escape attempt)" {
    run validate_docs_corpus "/jeap/docs-corpus/.."
    [ "$status" -ne 0 ]
}

# --- main(): stages only, prints the count, never indexes; guard still refuses dangerous values ---

@test "main refuses DOCS_CORPUS=/jeap/src and never calls rm" {
    run env PATH="$TMP/bin:$PATH" SRC_ROOT="$TMP/empty-src" DOCS_CORPUS="/jeap/src" "$SCRIPT"
    [ "$status" -ne 0 ]
    [ ! -f "$TMP/rm.log" ]      # validate runs before stage_docs's rm -> rm never reached
}

@test "main refuses DOCS_CORPUS=/jeap and never calls rm" {
    run env PATH="$TMP/bin:$PATH" SRC_ROOT="$TMP/empty-src" DOCS_CORPUS="/jeap" "$SCRIPT"
    [ "$status" -ne 0 ]
    [ ! -f "$TMP/rm.log" ]
}

@test "main accepts DOCS_CORPUS=/jeap/docs-corpus and prints 0 when no docs exist" {
    mkdir -p "$TMP/empty-src"
    # Suppress stderr so $output is exactly the staged-repo count printed on stdout.
    run env PATH="$TMP/bin:$PATH" SRC_ROOT="$TMP/empty-src" DOCS_CORPUS="/jeap/docs-corpus" \
        bash -c 'bash "$1" 2>/dev/null' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]         # nothing staged -> caller skips the jeap-docs pass
}

@test "main defaults unset DOCS_CORPUS to /jeap/docs-corpus and accepts it" {
    mkdir -p "$TMP/empty-src"
    run env PATH="$TMP/bin:$PATH" SRC_ROOT="$TMP/empty-src" "$SCRIPT"
    [ "$status" -eq 0 ]
}

# --- stage_docs(): idempotent staging ---

@test "stage_docs copies docs contents without docs/docs nesting" {
    mkdir -p "$TMP/src/jeap-messaging/docs" "$TMP/src/jeap/docs/overview"
    echo outbox > "$TMP/src/jeap-messaging/docs/outbox.md"
    echo arch   > "$TMP/src/jeap/docs/overview/architecture.md"

    run stage_docs "$TMP/src" "$TMP/corpus"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]                               # staged-repo count printed on stdout

    [ -f "$TMP/corpus/jeap-messaging/docs/outbox.md" ]
    [ -f "$TMP/corpus/jeap/docs/overview/architecture.md" ]
    [ ! -e "$TMP/corpus/jeap-messaging/docs/docs" ]   # contents copied, not the dir
}

@test "stage_docs is idempotent and drops deleted docs on re-run" {
    mkdir -p "$TMP/src/repoA/docs" "$TMP/src/repoB/docs"
    echo a > "$TMP/src/repoA/docs/a.md"
    echo b > "$TMP/src/repoB/docs/b.md"

    run stage_docs "$TMP/src" "$TMP/corpus"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
    [ -f "$TMP/corpus/repoA/docs/a.md" ]
    [ -f "$TMP/corpus/repoB/docs/b.md" ]

    # Delete a source doc, re-stage: the corpus is rebuilt, so a.md must disappear.
    rm -f "$TMP/src/repoA/docs/a.md"
    run stage_docs "$TMP/src" "$TMP/corpus"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
    [ ! -f "$TMP/corpus/repoA/docs/a.md" ]
    [ -f "$TMP/corpus/repoB/docs/b.md" ]
}

@test "stage_docs skips a symlinked top-level docs dir (no path traversal)" {
    # A repo whose `docs` is a symlink pointing OUTSIDE its checkout must not have the target's
    # contents copied into the corpus; a normal repo alongside it must still be staged.
    mkdir -p "$TMP/outside" "$TMP/src/evil" "$TMP/src/good/docs"
    echo secret > "$TMP/outside/secret.md"
    ln -s "$TMP/outside" "$TMP/src/evil/docs"
    echo ok > "$TMP/src/good/docs/ok.md"

    run stage_docs "$TMP/src" "$TMP/corpus"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]                                # only the real docs dir counted
    [ -f "$TMP/corpus/good/docs/ok.md" ]               # real docs staged
    [ ! -e "$TMP/corpus/evil" ]                        # symlinked-docs repo skipped entirely
    [ ! -e "$TMP/corpus/evil/docs/secret.md" ]         # target contents NOT copied
}

@test "stage_docs strips a symlinked file inside a real docs dir (no leak into corpus)" {
    # A repo with a REAL docs/ that contains a symlink to a file outside the checkout: the real docs
    # are staged, but the symlink must not survive into the corpus (cp -a would otherwise preserve
    # it, and project-rag follows symlinks on read).
    mkdir -p "$TMP/outside" "$TMP/src/repo/docs"
    echo secret > "$TMP/outside/secret.md"
    echo real > "$TMP/src/repo/docs/real.md"
    ln -s "$TMP/outside/secret.md" "$TMP/src/repo/docs/secret.md"   # absolute escape
    ln -s ../../../outside/secret.md "$TMP/src/repo/docs/rel.md"    # relative escape

    run stage_docs "$TMP/src" "$TMP/corpus"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]                                # repo still staged
    [ -f "$TMP/corpus/repo/docs/real.md" ]             # real file kept
    [ ! -e "$TMP/corpus/repo/docs/secret.md" ]         # symlink dropped, not followed
    [ ! -L "$TMP/corpus/repo/docs/secret.md" ]         # and not present as a dangling symlink
    [ ! -L "$TMP/corpus/repo/docs/rel.md" ]
    [ -f "$TMP/outside/secret.md" ]                    # the symlink target itself is untouched
}
