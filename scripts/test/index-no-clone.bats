#!/usr/bin/env bats
# Smoke test for scripts/jeap-index.sh --no-clone (A3a): no clone is attempted, the positionals are
# interpreted as <PROJECT_NAME> <CHECKOUT_DIR>, and the index_codebase request carries them. Runs
# without a real project-rag by stubbing PROJECT_RAG_BIN with a fake that answers the id:2 request.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../jeap-index.sh"
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/bin" "$TMP/corpus"
    # Fake git: must NOT be invoked in --no-clone mode.
    cat > "$TMP/bin/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "git \$*" >> "$TMP/git.log"
exit 1
EOF
    # Fake project-rag: log received JSON-RPC lines and answer the id:2 index request, then exit on EOF.
    cat > "$TMP/bin/fake-rag" <<EOF
#!/usr/bin/env bash
while IFS= read -r line; do
    printf '%s\n' "\$line" >> "$TMP/rag-in.log"
    case "\$line" in
        *'"id":2'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"ok"}]}}' ;;
    esac
done
EOF
    chmod +x "$TMP/bin/git" "$TMP/bin/fake-rag"
}

teardown() {
    rm -rf "$TMP"
}

@test "--no-clone indexes the staged tree without cloning" {
    run env PATH="$TMP/bin:$PATH" PROJECT_RAG_BIN="$TMP/bin/fake-rag" \
        bash "$SCRIPT" --no-clone jeap-docs "$TMP/corpus"
    [ "$status" -eq 0 ]
    [ ! -f "$TMP/git.log" ]                                  # no clone attempted
    grep -q '"project":"jeap-docs"' "$TMP/rag-in.log"
    grep -q "\"path\":\"$TMP/corpus\"" "$TMP/rag-in.log"
}

@test "--no-clone requires CHECKOUT_DIR" {
    run env PATH="$TMP/bin:$PATH" PROJECT_RAG_BIN="$TMP/bin/fake-rag" \
        bash "$SCRIPT" --no-clone jeap-docs
    [ "$status" -ne 0 ]
}

@test "--no-clone fails if the staged dir is missing" {
    run env PATH="$TMP/bin:$PATH" PROJECT_RAG_BIN="$TMP/bin/fake-rag" \
        bash "$SCRIPT" --no-clone jeap-docs "$TMP/missing"
    [ "$status" -ne 0 ]
}

# --- orthogonal flags: --strip-tests and the link rewrite apply in --no-clone mode too ---

@test "--no-clone --strip-tests strips src/test from the staged tree (still no clone)" {
    mkdir -p "$TMP/corpus/mod/src/test" "$TMP/corpus/mod/src/main"
    echo test > "$TMP/corpus/mod/src/test/FooTest.java"
    echo main > "$TMP/corpus/mod/src/main/Foo.java"
    run env PATH="$TMP/bin:$PATH" PROJECT_RAG_BIN="$TMP/bin/fake-rag" \
        bash "$SCRIPT" --no-clone --strip-tests jeap-docs "$TMP/corpus"
    [ "$status" -eq 0 ]
    [ ! -d "$TMP/corpus/mod/src/test" ]                 # --strip-tests honored under --no-clone
    [ -f "$TMP/corpus/mod/src/main/Foo.java" ]          # non-test sources untouched
    [ ! -f "$TMP/git.log" ]                             # --no-clone still skips the clone
}

@test "--no-clone removes symlinks from the staged tree before indexing" {
    # A symlink escaping the checkout must be stripped before project-rag (which follows symlinks on
    # read) ever sees the tree; the real file alongside it is kept and the target is left untouched.
    mkdir -p "$TMP/outside" "$TMP/corpus/mod/docs"
    echo secret > "$TMP/outside/secret.md"
    echo real > "$TMP/corpus/mod/docs/real.md"
    ln -s "$TMP/outside/secret.md" "$TMP/corpus/mod/docs/secret.md"
    run env PATH="$TMP/bin:$PATH" PROJECT_RAG_BIN="$TMP/bin/fake-rag" \
        bash "$SCRIPT" --no-clone jeap-docs "$TMP/corpus"
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/corpus/mod/docs/secret.md" ]           # symlink stripped before indexing
    [ ! -L "$TMP/corpus/mod/docs/secret.md" ]
    [ -f "$TMP/corpus/mod/docs/real.md" ]               # real file kept
    [ -f "$TMP/outside/secret.md" ]                     # target untouched (link removed, not target)
}

@test "--no-clone rewrites jeap-admin-ch doc links in the staged tree" {
    mkdir -p "$TMP/corpus/jeap-messaging/docs"
    echo 'see [outbox](https://github.com/jeap-admin-ch/jeap-messaging/blob/main/docs/outbox.md)' \
        > "$TMP/corpus/jeap-messaging/docs/index.md"
    run env PATH="$TMP/bin:$PATH" PROJECT_RAG_BIN="$TMP/bin/fake-rag" INDEXED_SLUGS="jeap-messaging" \
        bash "$SCRIPT" --no-clone jeap-docs "$TMP/corpus"
    [ "$status" -eq 0 ]
    grep -q '(jeap-messaging/docs/outbox.md)' "$TMP/corpus/jeap-messaging/docs/index.md"  # link rewritten
    ! grep -q 'github.com' "$TMP/corpus/jeap-messaging/docs/index.md"                       # external URL gone
}

# --- --exclude-docs: shape the index request so the repo-root docs/ is left OUT of THIS index ---
# project-rag matches index_codebase's exclude_patterns as a plain SUBSTRING of each file's absolute
# path, so jeap-index.sh sends the absolute prefix "<CHECKOUT_DIR>/docs/". That matches only the
# top-level docs/ subtree (a nested "<CHECKOUT_DIR>/<mod>/docs/" is not a superstring of it). The
# exclusion only shapes the request; the docs/ files must stay on disk so jeap-stage-docs.sh can stage
# them into the jeap-docs corpus.

@test "--exclude-docs adds exclude_patterns for the top-level docs dir" {
    run env PATH="$TMP/bin:$PATH" PROJECT_RAG_BIN="$TMP/bin/fake-rag" \
        bash "$SCRIPT" --no-clone --exclude-docs jeap-messaging "$TMP/corpus"
    [ "$status" -eq 0 ]
    grep -Fq "\"exclude_patterns\":[\"$TMP/corpus/docs/\"]" "$TMP/rag-in.log"   # absolute prefix sent
    grep -q '"project":"jeap-messaging"' "$TMP/rag-in.log"                       # project still correct
}

@test "without --exclude-docs no exclude_patterns are sent" {
    run env PATH="$TMP/bin:$PATH" PROJECT_RAG_BIN="$TMP/bin/fake-rag" \
        bash "$SCRIPT" --no-clone jeap-messaging "$TMP/corpus"
    [ "$status" -eq 0 ]
    ! grep -q 'exclude_patterns' "$TMP/rag-in.log"                               # opt-in only
}

@test "--exclude-docs composes with --strip-tests, and leaves docs/ on disk for staging" {
    mkdir -p "$TMP/corpus/mod/src/test" "$TMP/corpus/docs"
    echo test > "$TMP/corpus/mod/src/test/FooTest.java"
    echo doc  > "$TMP/corpus/docs/guide.md"
    run env PATH="$TMP/bin:$PATH" PROJECT_RAG_BIN="$TMP/bin/fake-rag" \
        bash "$SCRIPT" --no-clone --strip-tests --exclude-docs jeap-messaging "$TMP/corpus"
    [ "$status" -eq 0 ]
    [ ! -d "$TMP/corpus/mod/src/test" ]                                         # --strip-tests honored
    [ -f "$TMP/corpus/docs/guide.md" ]                                          # docs NOT deleted from disk
    grep -Fq "\"exclude_patterns\":[\"$TMP/corpus/docs/\"]" "$TMP/rag-in.log"   # docs excluded from index
}
