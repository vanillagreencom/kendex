# KEN-2428 full-history credential scan

No scanned repository holds a live credential in its history. Every finding is a test fixture or a false match.

## Method

- Each repository is a `git clone --mirror`, so the scan reads every branch, tag and pull request ref.
- The command is `gitleaks git --redact --ignore-gitleaks-allow -c cfg.toml REPO.git` with gitleaks 8.30.1. `cfg.toml` holds `[extend] useDefault = true`, the default rules the `secrets` lane runs.
- A finding counts as live only if it is a credential a service would accept. Each GitHub token finding was checked against the CRC32 checksum GitHub puts in the last six characters of a real token. None carries a valid checksum.
- The report names path, line and rule id only. No value was copied out of a clone.
- The scan ran on 2026-10-02 from a fleet lane. The lane's GitHub token reads the six public repositories and none of the twelve private ones.

## Results

| Repository under vanillagreencom | Visibility | Commits scanned | Seconds | Findings | Rules | Live |
| --- | --- | --- | --- | --- | --- | --- |
| kendex | public | 14143 | 25 | 99 in 30 files | generic-api-key 83, github-pat 10, slack-bot-token 4, private-key 2 | none |
| vgs | public | 3389 | 27 | 65 in 11 files | generic-api-key 52, private-key 7, slack-bot-token 6 | none |
| vsys | public | 784 | 3 | 12 in 3 files | generic-api-key 4, private-key 4, slack-bot-token 4 | none |
| vgs-themes | public | 7 | 1 | 0 | none | none |
| homebrew-kendex | public | 23 | 1 | 0 | none | none |
| gentoo-overlay | public | 13 | 1 | 0 | none | none |
| fleet, fleet-state, vg, talk, hyprtrade, hyprtrade-io, hyprtrade-pub, memsira, drovr, kendex-web, review-gate-sandbox, .github-private | private | not scanned | | | | |

## Findings by kind

- Test fixtures: fake tokens and key headers in test suites, such as `skills/orch/tests/secret-value.test.sh`, `skills/github/tests/pr-view.test.sh` and `crates/core/tests/quality/scoring.rs`. The `.agents/` paths in kendex, vgs and vsys are renders of kendex suites.
- False matches: a 64-character SHA-256 digest beside a file name in vgs `shell/plugins/vgs.jarvis/artifacts.json`, error strings in vgs `shell/plugins/vgs.jarvis/backend/keys.js` and kendex `crates/core/src/render/validate/agent.rs`, prose in `skills/review-gate/scripts/review-policy` and `docs/plans/linear-official-route-research.md`, and a repository name under a `repoKey` field in kendex UI fixtures.
- One test-only TLS private key for a local HTTPS stub in vgs `scripts/test-convert-v1-themes.js`. A later vgs commit generates that key per run and refuses committed private keys.

## Private repositories

The twelve private repositories need the same scan from a token that reads them, run by the owner:

```bash
git clone --mirror https://github.com/vanillagreencom/REPO.git REPO.git
printf '[extend]\nuseDefault = true\n' >cfg.toml
gitleaks git --no-banner --redact --ignore-gitleaks-allow -c cfg.toml \
  --report-format json --report-path REPO.json REPO.git
jq -r '.[] | [.File, .StartLine, .RuleID] | @tsv' REPO.json
```
