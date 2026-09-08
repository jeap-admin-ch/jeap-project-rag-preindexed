# What gets indexed, and internal-information considerations

This document captures findings from reviewing `scripts/jeap-index-all.sh`, `scripts/jeap-index.sh`,
`scripts/jeap-stage-docs.sh`, and `project-rag`'s file walker, in the context of making a downstream
consumer (`jeap-mcp-service`) publicly available on the internet.

## Where the indexed source actually comes from

| Source | Discovery | Repos included |
|---|---|---|
| **GitHub** `github.com/jeap-admin-ch` (public) | Dynamically discovered via the GitHub REST API, all non-archived public repos | Most jEAP repos, **minus** an explicit exclude list (`JEAP_EXCLUDE` in `jeap-index-all.sh`): this tooling's own repos, templates, CI-lib/publishing infra, and the org's own `.github`/docs-site repos |
| **GitHub** `github.com/jme-admin-ch` (public) | Dynamically discovered via the GitHub REST API, all non-archived public repos | JME repos, minus `JME_EXCLUDE` (the org's own `.github` repo, an integration-test repo) |

Both sources are public GitHub orgs: what's indexed is exactly what anyone can already `git clone`
today.

## What actually gets swept into the index

1. **Full application source, not just docs.** For JEAP repos, `src/test` is stripped
   (`--strip-tests`), but **JME repos keep their test code** (no `--strip-tests` for JME in
   `jeap-index-all.sh`). Test code can contain fixture credentials, sample tokens, or internal
   hostnames.
2. **Hidden/dotfiles are indexed by default.** `project-rag`'s file walker
   (`src/indexer/file_walker/mod.rs`) uses `.hidden(false)` and only explicitly skips `.git/**`.
   Everything else is walked (it does respect `.gitignore` / `.git/info/exclude` / global gitignore).
   So any committed dotfile (`.env`, `.npmrc`, `.aws/credentials`, CI files with inline secrets, IDE
   configs) **would be indexed** unless:
   - the repo's own `.gitignore` excludes it, **or**
   - it matches the small, fixed removal list in `jeap-index.sh`: `AGENTS.md`, `CHANGELOG.md`,
     `CONTRIBUTING.md`, `SECURITY.md`, `THIRD-PARTY-LICENSES.md`, `LICENSE`, `Jenkinsfile`,
     `publiccode.yml`, `setPomVersions.sh`, `mvnw`, `mvnw.cmd`, and the `.mvn/` directory.
3. **No secret-scanning/redaction pass.** Neither `project-rag`'s config
   (`src/config/mod.rs`) nor the indexing scripts run any automated detection or masking of API
   keys, tokens, or passwords before embedding. The only protection is whatever each repo's
   `.gitignore` already covers — i.e., a "hope nothing was committed by accident" model.

## Mitigations already in place

- **Symlinks are stripped** before indexing, both per-repo (`jeap-index.sh`) and in the docs-staging
  step (`jeap-stage-docs.sh`) — prevents a symlink from leaking files from outside the checkout into
  the index.
- **Shallow clone (`git clone --depth 1`)** — no git history is indexed, so old/deleted commits
  containing since-removed secrets are not exposed; only the current HEAD state is indexed.
- **`.git/` contents are explicitly excluded** from the walk (`file_walker/mod.rs`).
- **`jeap_version_overview`** (the downstream MCP tool) only fetches the public, unauthenticated
  `raw.githubusercontent.com/jeap-admin-ch/jeap` file — no token, no internal data involved.

## Recommendation before public exposure

Run a secret-scan (e.g. `gitleaks`/`trufflehog`) over the **actual indexed source tree**
(`/jeap/src` inside the built image, post strip/removal steps) before making any downstream consumer
of this index publicly reachable — don't rely solely on each repo's `.gitignore`. Since both JEAP and
JME now come from public GitHub orgs, the remaining risk is entirely about *content shape* (JME test
code kept in full, dotfiles indexed by default, no automated secret detection — see above), not about
sourcing internal-only material into a public index.
