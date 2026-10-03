# Copilot credit record

The record `lanes` produces for one Copilot account's monthly AI credit pool, read from GitHub's usage endpoint with the account's stored login by [`scripts/lib/copilot-credits.sh`](../scripts/lib/copilot-credits.sh), which owns the endpoint, the login layout and the rules for zero, overage and unlimited. A Pi root on a `github-copilot/` model yields the same record from the lane host's `harness=pi` accounts row for that root ([lane-host.md](lane-host.md)), or, where no row reads it, from its stated `ORCH_LANE_COPILOT_POOL` override.

## Where it is

- `lanes list --harness copilot --json` prints one record per account; `lanes pick --harness copilot --json` and `lanes pick --lane <dir> --harness copilot --json` print the judged one, with `wall` and the pick fields beside it.
- The endpoint's raw answer is cached, not the record: `usage/copilot-<cksum of the account dir>.json` under `$OVERSEE_WATCH_STATE_DIR`, else `<project root>/tmp/oversee-watch/usage`, as `{harness, config_dir, fetched_at, usage, prior}`, `fetched_at` in epoch seconds and `usage` the endpoint body. `lanes` re-parses it through the library on every read.

## Fields

| Field | Meaning |
|---|---|
| `harness` | `copilot`, or `pi` for a Pi root's pool, from a provider `harness=pi` row or the stated override |
| `config_dir` | The account: the `COPILOT_HOME` directory, or the Pi root |
| `alias` | The account's label (`ORCH_LANE_ALIASES`, else the directory name) |
| `measured_through` | `local` for this machine's read, `host` for a provider's `accounts` row, `stated` for `ORCH_LANE_COPILOT_POOL` |
| `status` | `ok` or `rate_limited` where measured; `no_credentials` with `detail` naming the login's reason (`config-missing`, `config-unreadable`, `token-missing`, `token-ambiguous`, `token-foreign-host`; for a login config.json names and the Linux Secret Service holds, read through `secret-tool`, `keyring-absent`, `keyring-locked`, `keyring-refused`, `keyring-empty`, where `keyring-absent` also covers a platform whose credential store is not the Secret Service, such as the macOS Keychain, which is not read); `no_usage_data` where the answer measured nothing; `refused`, `unreachable` or `error` for a failed read |
| `monthly_pct` | Share of the grant used, whole percent rounded up; 100 at or past the grant; 0 for an unlimited seat; null where unmeasured |
| `unlimited` | `true` only for a seat the endpoint marks `unlimited: true` |
| `headroom_pct` | 100 minus `monthly_pct`, null where unmeasured |
| `binding_bucket`, `binding_resets_at`, `resets.monthly` | `monthly` and the pool's reset, ISO 8601 UTC, from `quota_reset_date_utc`. All null for an unmeasured account; a provider row's reset is its `monthly-resets`; the reset is null for a stated reading and wherever the endpoint or the row gives no date |
| `usage_age_s` | Seconds since the endpoint answered the figure served |
| `credits` | The counts, below; null where unmeasured |

`credits`, for a counted pool:

| Field | Meaning |
|---|---|
| `unit` | `AIC`, AI credits |
| `unlimited` | `false` |
| `used` | `entitlement` less `remaining`, the figure `monthly_pct` is judged from, never the endpoint's `credits_used`; for a stated reading, the stated used |
| `granted` | The monthly grant, `entitlement`; for a stated reading, the stated grant |
| `remaining` | `remaining`; for a stated reading, the grant less the used, never below 0 |
| `over`, `overage_permitted`, `token_based_billing` | `overage_count`, `overage_permitted` and `token_based_billing` as given; absent for a stated reading. `overage_permitted` never makes a pool at zero room |
| `measured_at` | When the figure was read, ISO 8601 UTC |

`credits` for an unlimited seat is `{unit: "AIC", unlimited: true, measured_at}`.

A provider's `accounts` row carries a Copilot account as `harness=copilot`, or a Pi root's pool as `harness=pi`, with `monthly-pct` and `monthly-resets` ([lane-host.md](lane-host.md)), and its record carries no `credits`.
