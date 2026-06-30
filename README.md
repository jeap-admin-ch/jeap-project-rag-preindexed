# jeap-project-rag-index

Builds the `bit/jeap-project-rag-preindexed` Docker image: the upstream
[`jeap-project-rag`](https://bitbucket.bit.admin.ch/plugins/servlet/branch-permissions/JEAP/jeap-project-rag)
MCP server bundled with a pre-populated LanceDB index of a curated set of JEAP library source code and JME
example repositories.

Consumers of the image get instant semantic search over the JEAP codebase
without having to clone and index the repos themselves.

There is no application code in this repository - it is a thin shell/Docker
harness around the upstream `jeap-project-rag` binary meant to be used
index the jEAP codebase regularly to be used in the jEAP MCP server.

## Build

```bash
# Build locally (matches what CI does)
docker build -t bit/jeap-project-rag-preindexed:dev .

# Pin a specific upstream base image tag
docker build \
  --build-arg JEAP_PROJECT_RAG_TAG=0.1.0-al2023-20260508043103 \
  -t bit/jeap-project-rag-preindexed:dev .
```

CI builds the image and publishes it using the tag `${baseTag}-${UTC timestamp}` (e.g. `0.1.0-al2023-20260508043103`).

## Run

The image launches the `project-rag` MCP server with the pre-built index
already in place. Point an MCP client at it over stdio:

```bash
docker run --rm -i bit/jeap-project-rag-preindexed:dev
```

The embedding model lives at `/home/raguser/models/all-MiniLM-L6-v2` and is
referenced via the `PROJECT_RAG_MODEL_PATH` env var baked into the image. Cloned sources
remain available under `/jeap/src/<project>` for tools that want to read
indexed files directly. If you want to minimize image size, you might want to
skip copying the source code directory to the final image and only keep the LanceDB index.

## Using in downstream images

Downstream images can `COPY --from` the preindexed image to pull in the
`project-rag` binary, the LanceDB index, the embedding model, and (optionally)
the cloned sources. The example below shows a Spring Boot service image that
embeds the index and runs the MCP server under a non-root `appuser`:

```dockerfile
# Stage 1: alias the preindexed image so we can COPY from it.
ARG PREINDEXED_TAG=0.1.0-al2023-20260513080314
FROM repo.bit.admin.ch:8444/bit/jeap-project-rag-preindexed:${PREINDEXED_TAG} AS rag

# Stage 2: the existing runtime image, enriched with project-rag + index, based on up-to-date base image
FROM 211125750372.dkr.ecr.eu-central-2.amazonaws.com/jeap-runtime-coretto:25.20251119043107

COPY --from=rag /usr/local/bin/project-rag /usr/local/bin/project-rag

COPY --from=rag /home/raguser/.local/share/project-rag /home/appuser/.local/share/project-rag
COPY --from=rag /home/raguser/.cache/project-rag       /home/appuser/.cache/project-rag

# Embedding model - relocated from /home/raguser/models to /opt/models
COPY --from=rag /home/raguser/models           /opt/models

# jEAP Source code
COPY --from=rag /jeap/src                      /jeap/src

# Prebuilt LanceDB index - relocated from /home/raguser/.local/share/project-rag/lancedb
# so the data path is independent of the runtime user.
COPY --from=rag /home/raguser/.local/share/project-rag/lancedb /opt/jeap-rag/lancedb

# Ensure appuser owns all files it needs to read/write at runtime.
# Switch to root first - chown requires root regardless of the base image's USER directive.
USER root
RUN chown -R appuser:appuser \
        /home/appuser/.local/share/project-rag \
        /home/appuser/.cache/project-rag \
        /opt/jeap-rag/lancedb
USER appuser

ENV PROJECT_RAG_MODEL_PATH=/opt/models/all-MiniLM-L6-v2 \
    PROJECT_RAG_LANCEDB_PATH=/opt/jeap-rag/lancedb \
    MCP_CLIENT_ENABLED=true

# Copy deployable web module artifact using project-rag
COPY target/my-mcp-service.jar app.jar

ENTRYPOINT ["java", "-jar", "app.jar"]
```

Notes:

- The source image indexes as `raguser`, so the data lives under
  `/home/raguser/.local/share/project-rag` and `/home/raguser/.cache/project-rag`. Copy it to a
  path owned by your runtime user and `chown` it before switching to that user.
- Omit the `COPY --from=rag /jeap/src ...` line if you do not need the cloned
  sources at runtime - this is the biggest size contributor.

## Architecture

The `Dockerfile` is a two-stage build:

1. **`indexer` stage** - extends the upstream base image, installs build-only
   tooling (`git`, `curl`, `findutils`, `jq` for Bitbucket repo discovery, and
   `perl` for the doc-link rewrite), then runs `scripts/jeap-index-all.sh`
   to clone and index every listed repo. The `all-MiniLM-L6-v2` embedding model
   is not downloaded here - the base image ships it pre-downloaded under
   `/home/raguser/models`. Indexing writes to `~/.local/share/project-rag`
   (LanceDB) and `~/.cache/project-rag`.
2. **`final` stage** - same upstream base, but only the index artifacts, the
   embedding model, and the cloned sources are copied over. Build-only tooling
   (e.g. `git`) is left out of the shipped image.

### Indexing flow

`scripts/jeap-index-all.sh` indexes three sets of repos and invokes
`scripts/jeap-index.sh` once per repo:

- **JEAP** infrastructure repos (Bitbucket project `JEAP`, under `scm/jeap`) and
  **JME** example repos (Bitbucket project `BIT_JME`, under `scm/bit_jme`) are
  **auto-discovered from the Bitbucket REST API** at build time. Archived repos
  are skipped automatically, and repos whose slug is listed in the `JEAP_EXCLUDE`
  / `JME_EXCLUDE` arrays are dropped. New repos are picked up automatically on the
  next build unless excluded.
- **GitHub** public OSS repos under `github.com/jeap-admin-ch` are a **static
  list** (`GITHUB_REPOS`); these are public, so the clone needs no credentials.

JEAP repos and the GitHub OSS repos are indexed with `--strip-tests` so
`src/test` trees are excluded, as these tests are usually not relevant for coding
agents writing applications using jEAP. JME example repos keep their tests
because the tests are part of the example. **All** per-repo passes additionally use
`--exclude-docs` so each repo's top-level `docs/` is left out of the per-repo
`project=<slug>` index and indexed once under `project=jeap-docs` instead (see
[Dedicated `jeap-docs` project](#dedicated-jeap-docs-project) below).

#### Documentation link rewrite

Before indexing each repo, `scripts/jeap-index.sh` calls
`scripts/jeap-rewrite-doc-links.sh` to rewrite `jeap-admin-ch` GitHub links inside
Markdown files (`*.md` / `*.markdown`, including a repo-root `README.md`) into
index-local, repo-prefixed paths (e.g.
`https://github.com/jeap-admin-ch/jeap-messaging/blob/main/docs/outbox.md#config`
→ `jeap-messaging/docs/outbox.md#config`). A trailing `#fragment` is preserved; a
`?query` string is dropped. Only links to repositories that are actually indexed
are rewritten (the indexed-slug whitelist is threaded as the `INDEXED_SLUGS` env
var); links to excluded/non-indexed repos and any non-`jeap-admin-ch` link are left
as their original external URL. The rewrite is idempotent.

Only **default-branch** links are rewritten: the ref segment must be `main` or
`master`. Links pinned to any other ref — a tag, a commit SHA, or a non-`main`/`master`
branch — are intentionally left external, because the index is a depth-1 clone of each
repo's default branch and does not contain that other content. (A ref that literally
starts with `main/` or `master/`, e.g. a branch named `main/next`, is treated as the
default branch; such refs are exotic and the URL alone cannot disambiguate them.)

#### Dedicated `jeap-docs` project

After the three per-repo passes, `jeap-stage-docs.sh` stages every `*/docs` subtree
found under `/jeap/src` into a single corpus root (`/jeap/docs-corpus`, overridable
via `DOCS_CORPUS`) and prints the number of staged repos. `jeap-index-all.sh` then
indexes that corpus **once** as `project=jeap-docs` using `jeap-index.sh --no-clone`,
skipping the pass when nothing was staged. Because the corpus is rooted at
`/jeap/docs-corpus`, the indexed `file_path` carries the `<repo>/` segment (e.g.
`jeap-messaging/docs/outbox.md`), giving downstream consumers a clean, corpus-wide
documentation project. The staging step is idempotent (it cleans the corpus first
and copies directory *contents*). The `jeap-docs` corpus lives only in the `indexer`
stage; the `final` stage copies `/jeap/src` (not `/jeap/docs-corpus`). project-rag stores
the chunk text in LanceDB, so the index serves documentation content even though the
corpus files themselves are not shipped.

**Why a separate project (deduplication).** The three per-repo passes run with
`--exclude-docs`, so a repo's top-level `docs/` is indexed *only* as `jeap-docs`, never
under `project=<slug>`. If docs were indexed in both, every doc chunk would exist twice
with identical embeddings, and a search without a `project` filter would return the same
chunk twice — halving the useful results in the top-k. The trade-off: a `project=<slug>`
search returns **code only**; that repo's documentation is searchable under
`project=jeap-docs`. (A repo-root `README.md` / `AGENTS.md` is not under `docs/`, so it
stays with the per-repo project and was never duplicated.) Implementation note:
`index_codebase` matches `exclude_patterns` as a plain **substring** of each file's
absolute path — *not* a glob, despite what the tool's schema description suggests — so
`jeap-index.sh` passes the absolute prefix `"<CHECKOUT_DIR>/docs/"`. That matches the
top-level `docs/` only; a nested `<module>/docs/` is not a superstring of it and stays in
the per-repo index (it is not staged into `jeap-docs`, which collects only top-level
`*/docs`).

## Adding or removing repositories

JEAP and JME repos are **auto-discovered** from the Bitbucket API, so new repos
are indexed automatically on the next build (archived repos are skipped). To
**exclude** one, add its slug to the `JEAP_EXCLUDE` or `JME_EXCLUDE` array in
`scripts/jeap-index-all.sh`. GitHub OSS repos are a static list - edit the
`GITHUB_REPOS` array to add or remove one. The repo slug doubles as the `project`
name passed to `index_codebase`.

## Configurable environment variables

| Variable                             | Default                                      | Purpose                        |
|--------------------------------------|----------------------------------------------|--------------------------------|
| `BITBUCKET_BASE_URL`                 | `https://bitbucket.bit.admin.ch`             | Base URL for Bitbucket repo discovery (JEAP/JME) |
| `JEAP_GIT_BASE_URL` / `GIT_BASE_URL` | `https://bitbucket.bit.admin.ch/scm/jeap`    | Base URL for JEAP repos        |
| `JME_GIT_BASE_URL`                   | `https://bitbucket.bit.admin.ch/scm/bit_jme` | Base URL for JME example repos |
| `GITHUB_GIT_BASE_URL`                | `https://github.com/jeap-admin-ch`           | Base URL for GitHub OSS repos  |
| `JEAP_INDEX_BIN`                     | `/home/raguser/bin/jeap-index.sh`            | Per-repo indexer script        |
| `PROJECT_RAG_BIN`                    | `/usr/local/bin/project-rag`                 | Upstream MCP server binary     |
| `PROJECT_RAG_MODEL_PATH`             | `/home/raguser/models/all-MiniLM-L6-v2`      | Embedding model location       |
| `DOCS_CORPUS`                        | `/jeap/docs-corpus`                          | Staging root for the `jeap-docs` project (must be `/jeap/docs-corpus` or a subpath) |
| `INDEXED_SLUGS`                      | _(computed)_                                 | Whitespace-separated indexed-repo whitelist for the link rewrite; set automatically by `jeap-index-all.sh` |
