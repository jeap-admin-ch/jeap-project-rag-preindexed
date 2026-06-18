# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

## Purpose

This repo builds a Docker image (`bit/jeap-project-rag-preindexed`) that ships `jeap-project-rag` with a pre-populated LanceDB index of a curated set of JEAP library and JME example repositories. The image is consumed downstream so users get instant semantic search over JEAP code without having to clone and index repos themselves. CI rebuilds it on a schedule (`Jenkinsfile` cron) so the index stays current.

There is **no application code here** — the repo is a thin shell/Docker harness around the upstream `jeap-project-rag` binary.

## Build

```bash
# Build the image locally (matches what Jenkins does)
docker build -t bit/jeap-project-rag-preindexed:dev .

# Override the upstream base image tag if needed
docker build --build-arg JEAP_PROJECT_RAG_TAG=<tag> -t bit/jeap-project-rag-preindexed:dev .

# Run the pre-built MCP server over stdio
docker run --rm -i bit/jeap-project-rag-preindexed:dev
```

CI builds via `Jenkinsfile` using `dockerPipelineTemplate`, publishing `${baseTag}-${UTC timestamp}` and `latest` (e.g. `0.1.0-al2023-20260520112321`). `masterBranchName` is `master`.

## Architecture

The Dockerfile is a two-stage build over `repo.bit.admin.ch:8444/bit/jeap-project-rag:${JEAP_PROJECT_RAG_TAG}`:

1. **`indexer` stage** — installs build-only tooling (`git`, `curl`, `findutils`) via `dnf`, then runs `jeap-index-all.sh` to clone+index every listed repo. The embedding model is **not** downloaded here — the base image ships it pre-downloaded under `/home/raguser/models`. Indexing writes to `~/.local/share/project-rag` (LanceDB) and `~/.cache/project-rag`.
2. **`final` stage** — same base, but only the index artifacts (`~/.local/share/project-rag`, `~/.cache/project-rag`), the model (`/home/raguser/models`), and the cloned sources (`/jeap/src`) are copied over. This keeps `git` and other build-only tooling out of the shipped image.

`PROJECT_RAG_MODEL_PATH=/home/raguser/models/all-MiniLM-L6-v2` tells `project-rag` where to find the embedding model at runtime.

Downstream images `COPY --from` this image to pull in the `project-rag` binary, the LanceDB index, the model, and (optionally) `/jeap/src`. Indexing runs as `raguser`, so artifacts live under `/home/raguser/...` — downstream consumers must `chown` them to their runtime user. See `README.md` for a full downstream Dockerfile example.

### Indexing flow

`scripts/jeap-index-all.sh` declares three repo lists (JEAP infra repos under `scm/jeap`, JME example repos under `scm/bit_jme`, and public OSS repos under `github.com/jeap-admin-ch`) and calls `scripts/jeap-index.sh` once per repo. Stops at the first failure (`set -euo pipefail`).

- **JEAP repos** are indexed with `--strip-tests`, which deletes `src/test` trees before indexing — those tests are rarely relevant to agents writing applications *with* jEAP.
- **JME example repos** are indexed in full, because their tests are part of the example.
- **GitHub OSS repos** are indexed with `--strip-tests`, same as the JEAP infra repos. These are public, so the clone needs no credentials.

`scripts/jeap-index.sh` does the actual work for one repo:

- `git clone --depth 1` into `/jeap/src/<project>` (then strips `src/test` if `--strip-tests` was passed)
- Spawns the `project-rag` MCP server as a bash coproc (stdio JSON-RPC)
- Sends `initialize` → `notifications/initialized` → `tools/call index_codebase` with `{path, project}`
- Reads server responses line-by-line, watching for `"id":2` to know indexing finished, and inspects for `"error"` or `"isError":true` to set exit status
- Closes the server's stdin so it exits cleanly

JEAP and JME repos are **auto-discovered** from the Bitbucket API at build time. Archived repos are skipped
automatically. To exclude a repo from indexing, add its slug to the `JEAP_EXCLUDE` or `JME_EXCLUDE` arrays in
`jeap-index-all.sh`. New repos appear in the index automatically on the next build unless explicitly excluded. GitHub
repos remain a static list (`GITHUB_REPOS`).

### Configurable env vars

- `BITBUCKET_BASE_URL` — defaults to `https://bitbucket.bit.admin.ch`
- `JEAP_GIT_BASE_URL` / `GIT_BASE_URL` — defaults to `${BITBUCKET_BASE_URL}/scm/jeap`
- `JME_GIT_BASE_URL` — defaults to `${BITBUCKET_BASE_URL}/scm/bit_jme`
- `GITHUB_GIT_BASE_URL` — defaults to `https://github.com/jeap-admin-ch`
- `JEAP_INDEX_BIN` — path to the per-repo indexer (default `/home/raguser/bin/jeap-index.sh`)
- `PROJECT_RAG_BIN` — path to the upstream MCP server binary (default `/usr/local/bin/project-rag`)

## Local development of the indexing scripts

To iterate on the shell scripts without rebuilding the full image, run a container from the upstream `jeap-project-rag` base image, bind-mount the `scripts/` dir, and execute `jeap-index.sh [--strip-tests] <repo-url> <project-name>` inside it. The scripts assume `project-rag` and `git` are on `PATH` and that the embedding model is reachable via `PROJECT_RAG_MODEL_PATH`.
