# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

## Purpose

This repo builds a Docker image (`ghcr.io/jeap-admin-ch/jeap-project-rag-preindexed`) that ships `jeap-project-rag` with a pre-populated LanceDB index of a curated set of JEAP library and JME example repositories. The image is consumed downstream so users get instant semantic search over JEAP code without having to clone and index repos themselves. CI rebuilds it on a schedule (`Jenkinsfile` cron) so the index stays current.

There is **no application code here** — the repo is a thin shell/Docker harness around the upstream `jeap-project-rag` binary.

## Build

```bash
# Build the image locally (matches what Jenkins does)
docker build -t jeap-project-rag-preindexed:dev .

# Override the upstream base image tag if needed
docker build --build-arg JEAP_PROJECT_RAG_TAG=<tag> -t jeap-project-rag-preindexed:dev .

# Run the pre-built MCP server over stdio
docker run --rm -i jeap-project-rag-preindexed:dev
```

CI builds via `Jenkinsfile` using `dockerPipelineTemplate`, publishing `${baseTag}-${UTC timestamp}` and `latest` (e.g. `0.1.0-al2023-20260520112321`). `masterBranchName` is `master`.

## Architecture

The Dockerfile is a two-stage build over `ghcr.io/jeap-admin-ch/jeap-project-rag:${JEAP_PROJECT_RAG_TAG}`:

1. **`indexer` stage** — installs build-only tooling (`git`, `curl`, `findutils`, `jq` for GitHub repo discovery, `python3` for the doc-link rewrite) via `dnf`, then runs `jeap-index-all.sh` to clone+index every listed repo. The embedding model is **not** downloaded here — the base image ships it pre-downloaded under `/home/raguser/models`. Indexing writes to `~/.local/share/project-rag` (LanceDB) and `~/.cache/project-rag`.
2. **`final` stage** — same base, but only the index artifacts (`~/.local/share/project-rag`, `~/.cache/project-rag`), the model (`/home/raguser/models`), and the cloned sources (`/jeap/src`) are copied over. This keeps `git` and other build-only tooling out of the shipped image.

`PROJECT_RAG_MODEL_PATH=/home/raguser/models/all-MiniLM-L6-v2` tells `project-rag` where to find the embedding model at runtime.

Downstream images `COPY --from` this image to pull in the `project-rag` binary, the LanceDB index, the model, and (optionally) `/jeap/src`. Indexing runs as `raguser`, so artifacts live under `/home/raguser/...` — downstream consumers must `chown` them to their runtime user. See `README.md` for a full downstream Dockerfile example.

### Indexing flow

`scripts/jeap-index-all.sh` indexes two sets of repos and calls `scripts/jeap-index.sh` once per repo: JEAP infra repos are **auto-discovered from the public `jeap-admin-ch` GitHub org**, and JME example repos are **auto-discovered from the public `jme-admin-ch` GitHub org** (archived/excluded repos dropped from both). Stops at the first failure (`set -euo pipefail`).

- **JEAP repos** are indexed with `--strip-tests --exclude-docs`: `--strip-tests` deletes `src/test` trees before indexing (those tests are rarely relevant to agents writing applications *with* jEAP), and `--exclude-docs` keeps the repo-root `docs/` out of the per-repo index (deduplication — see the `jeap-docs` section below). These are public, so the clone needs no credentials.
- **JME example repos** keep their tests (no `--strip-tests`, because the tests are part of the example) but are still indexed with `--exclude-docs`.

`scripts/jeap-index.sh` does the actual work for one repo as three independent steps:

1. **Obtain the tree** — `git clone --depth 1` into `/jeap/src/<project>`, or (with `--no-clone`) verify the already-staged `CHECKOUT_DIR` exists. This is the only step that depends on clone vs. no-clone.
2. **Strip tests** — delete `src/test` trees if `--strip-tests` was passed. Applies in both modes.
3. **Rewrite doc links** — rewrite `jeap-admin-ch` GitHub links in Markdown to index-local paths via `scripts/jeap-rewrite-doc-links.py`. Always attempted (both modes); the helper no-ops when `INDEXED_SLUGS` is unset and is idempotent, so it is safe to run on an already-rewritten staged corpus.

Then it indexes:

- Spawns the `project-rag` MCP server as a bash coproc (stdio JSON-RPC)
- Sends `initialize` → `notifications/initialized` → `tools/call index_codebase` with `{path, project}` (plus `exclude_patterns: ["<CHECKOUT_DIR>/docs/"]` when `--exclude-docs` is set)
- Reads server responses line-by-line, watching for `"id":2` to know indexing finished, and inspects for `"error"` or `"isError":true` to set exit status
- Closes the server's stdin so it exits cleanly

The flags are **orthogonal** — `--no-clone` only skips the clone (and the `REPO_URL` positional), `--strip-tests` only strips `src/test`, and `--exclude-docs` only adds the `exclude_patterns` entry to the index request (it does **not** touch the tree on disk, so the `docs/` files remain for staging); any combination is valid. `--no-clone <PROJECT_NAME> <CHECKOUT_DIR>` is used for the `jeap-docs` pass below (without `--exclude-docs`, since that pass *is* the docs index). Under `--no-clone`, steps 2–3 mutate the caller's staged tree (for `jeap-docs` that tree is a throwaway copy).

### Documentation: link rewrite and the `jeap-docs` project

- **Link rewrite (`scripts/jeap-rewrite-doc-links.py`)** — run per repo before indexing. Rewrites `jeap-admin-ch` GitHub links in `*.md` / `*.markdown` (incl. repo-root `README.md`) to index-local, repo-prefixed paths: `blob`/`raw`/`tree`/`raw.githubusercontent.com` and bare-repo URLs → `<repo>/<path>`. A `#fragment` is preserved, a `?query` is dropped. Only **default-branch** links are rewritten — the ref must be `main` or `master`; links pinned to another ref (tag, commit SHA, or a non-`main`/`master` branch) stay external, since the index is a depth-1 clone of the default branch and lacks that content (a ref literally starting with `main/`/`master/` is treated as the default branch — exotic and not disambiguable from the URL). Only links whose `<repo>` is in `INDEXED_SLUGS` are rewritten (others stay external); idempotent. `INDEXED_SLUGS` is the combined `JEAP_REPOS + JME_REPOS` whitelist, exported by `jeap-index-all.sh`.
- **`jeap-docs` project (`jeap-index-all.sh`)** — after the two per-repo passes, `jeap-stage-docs.sh` stages every `*/docs` subtree under `/jeap/src` into `$DOCS_CORPUS` (default `/jeap/docs-corpus`) and prints the number of staged repos. `jeap-index-all.sh` then indexes that corpus **once** as `project=jeap-docs` via `jeap-index.sh --no-clone` (skipping the pass when the count is 0). Rooting the corpus at `/jeap/docs-corpus` makes the indexed `file_path` carry the `<repo>/` segment (`<repo>/docs/<topic>.md`). The staging is idempotent (cleans the corpus, copies directory *contents*). A guard refuses to `rm -rf` a `DOCS_CORPUS` that is not `/jeap/docs-corpus` (or a subpath) or that contains `..`, so the cloned sources can never be deleted. The corpus is build-stage only — the `final` stage copies `/jeap/src`, not `/jeap/docs-corpus` (project-rag stores chunk text in LanceDB, so doc content is served from the index even though the corpus files are not shipped).
- **Deduplication via `--exclude-docs`** — the two per-repo passes run with `--exclude-docs`, so a repo's top-level `docs/` is indexed **only** as `jeap-docs`, never under `project=<slug>`. Without this, every doc file would be embedded twice with identical text, and a search with **no `project` filter** would return the same chunk twice, halving the useful top-k slots. Consequence: a `project=<slug>` search returns **code only** — that repo's documentation is searchable under `project=jeap-docs`. (A repo-root `README.md` / `AGENTS.md` is not under `docs/`, so it stays with the per-repo project and was never duplicated.) Implementation detail: `index_codebase` matches `exclude_patterns` as a plain **substring** of each file's absolute path — *not* a glob, despite the tool's schema description claiming glob syntax — so `jeap-index.sh` passes the absolute prefix `"<CHECKOUT_DIR>/docs/"`. That matches the top-level `docs/` only; a nested `<module>/docs/` is not a superstring of it and stays in the per-repo index (it is not staged into `jeap-docs`, which collects only top-level `*/docs`).

JEAP and JME repos are both **auto-discovered** from their public GitHub orgs at build time. Archived repos are
skipped automatically. To exclude a repo from indexing, add its name to the `JEAP_EXCLUDE` or `JME_EXCLUDE` arrays in
`jeap-index-all.sh`. New repos appear in the index automatically on the next build unless explicitly excluded.

### Configurable env vars

- `JEAP_GITHUB_ORG` — defaults to `jeap-admin-ch`
- `JME_GITHUB_ORG` — defaults to `jme-admin-ch`
- `GITHUB_API_URL` — defaults to `https://api.github.com`
- `GITHUB_TOKEN` — optional; raises the unauthenticated GitHub API rate limit if set, not required for public repos
- `JEAP_GIT_BASE_URL` / `GIT_BASE_URL` — defaults to `https://github.com/${JEAP_GITHUB_ORG}`
- `JME_GIT_BASE_URL` — defaults to `https://github.com/${JME_GITHUB_ORG}`
- `JEAP_INDEX_BIN` — path to the per-repo indexer (default `/home/raguser/bin/jeap-index.sh`)
- `PROJECT_RAG_BIN` — path to the upstream MCP server binary (default `/usr/local/bin/project-rag`)

## Local development of the indexing scripts

To iterate on the shell scripts without rebuilding the full image, run a container from the upstream `jeap-project-rag` base image, bind-mount the `scripts/` dir, and execute `jeap-index.sh [--strip-tests] [--exclude-docs] <repo-url> <project-name>` inside it. The scripts assume `project-rag` and `git` are on `PATH` and that the embedding model is reachable via `PROJECT_RAG_MODEL_PATH`.
