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

The embedding model lives at `/opt/models/all-MiniLM-L6-v2` and is referenced
via the `PROJECT_RAG_MODEL_PATH` env var baked into the image. Cloned sources
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

# Embedding model
COPY --from=rag /opt/models                    /opt/models

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

1. **`indexer` stage** - extends the upstream base image, installs `git`,
   downloads the `all-MiniLM-L6-v2` ONNX embedding model from HuggingFace into
   `/opt/models`, then runs `scripts/jeap-index-all.sh` to clone and index
   every listed repo. Indexing writes to `~/.local/share/project-rag`
   (LanceDB) and `~/.cache/project-rag`.
2. **`final` stage** - same upstream base, but only the index artifacts, the
   embedding model, and the cloned sources are copied over. Build-only tooling
   (e.g. `git`) is left out of the shipped image.

### Indexing flow

`scripts/jeap-index-all.sh` declares two repo lists - JEAP infrastructure
repos under `jeap` and JME example repos under `bit_jme` - and invokes
`scripts/jeap-index.sh` once per repo. JEAP repos are indexed with `--strip-tests` so `src/test`
trees are excluded as these tests are usually not relevant for coding agents
writing application using jEAP. JME example repos are indexed in full because
the tests are part of the example.

## Adding or removing repositories

Edit the `JEAP_REPOS` or `JME_REPOS` arrays in `scripts/jeap-index-all.sh`. The repo name doubles as the `project` name
passed to `index_codebase`.

## Configurable environment variables

| Variable                             | Default                                      | Purpose                        |
|--------------------------------------|----------------------------------------------|--------------------------------|
| `JEAP_GIT_BASE_URL` / `GIT_BASE_URL` | `https://bitbucket.bit.admin.ch/scm/jeap`    | Base URL for JEAP repos        |
| `JME_GIT_BASE_URL`                   | `https://bitbucket.bit.admin.ch/scm/bit_jme` | Base URL for JME example repos |
| `JEAP_INDEX_BIN`                     | `/home/raguser/bin/jeap-index.sh`            | Per-repo indexer script        |
| `PROJECT_RAG_BIN`                    | `/usr/local/bin/project-rag`                 | Upstream MCP server binary     |
| `PROJECT_RAG_MODEL_PATH`             | `/opt/models/all-MiniLM-L6-v2`               | Embedding model location       |
