# Copilot credit record

The record the runtime's account listing produces for one Copilot account's monthly AI credit pool, read from GitHub's usage endpoint with the account's stored login. [`runtime/src/ops/accounts/listing.rs`](../../agent-runtime/runtime/src/accounts/listing.rs) owns the endpoint and the login layout, and `parse_copilot` in [`usage.rs`](../../agent-runtime/runtime/src/accounts/usage.rs) the rules for zero, overage and unlimited. A Pi root on a `github-copilot/` model yields the same record from the lane host's `harness=pi` accounts row for that root ([lane-host.md](lane-host.md)), or, where no row reads it, from its stated `ORCH_LANE_COPILOT_POOL` override.

## Where it is

- `orch-runtime accounts roster` prints one record per account in `result.rows[].record`; `orch-runtime accounts pick --fleet --harness copilot` and `orch-runtime accounts pick --fleet --lane <dir> --harness copilot` reply with the judged one, with `wall` and the pick fields beside it.
- The endpoint's answer is kept in one usage record per account, `usage/copilot-<cksum of the account dir>-<its length>.json` under `$OVERSEE_WATCH_STATE_DIR`, else `<project root>/tmp/oversee-watch/usage`, beside a refusal and its window where the endpoint refused (`runtime/src/ops/accounts/cache.rs`). Every reader of that directory serves what another wrote while the figure is younger than `ORCH_LANES_USAGE_TTL`, or a caller's longer `ORCH_LANES_USAGE_MAX_AGE`; a TTL of 0 serves none. A record that does not parse as that shape, or names another account, is a miss, and the account is measured again; a field another reader added is dropped when the record is rewritten (`read` and `Record` in `cache.rs`).

## Fields

| Field | Meaning |
|---|---|
| `harness` | `copilot`, or `pi` for a Pi root's pool, from a provider `harness=pi` row or the stated override |
| `config_dir` | The account: the `COPILOT_HOME` directory, or the Pi root |
| `alias` | The account's label (`ORCH_LANE_ALIASES`, else the directory name) |
| `measured_through` | `local` for this machine's read, `host` for a provider's `accounts` row, `stated` for `ORCH_LANE_COPILOT_POOL` |
| `status` | `ok` or `rate_limited` where measured; `no_credentials` with `detail` naming the login's reason (`config-missing`, `config-unreadable`, `token-missing`, `token-ambiguous`, `token-foreign-host`; for a login config.json names and the Linux Secret Service holds, read through `secret-tool`, `keyring-absent`, `keyring-locked`, `keyring-refused`, `keyring-empty`, where `keyring-absent` also covers a platform whose credential store is not the Secret Service, such as the macOS Keychain, which is not read); `no_usage_data` where the answer measured nothing; `refused`, `unreachable` or `error` for a failed read |
| `monthly_pct` | Share of the grant used, whole percent rounded up; 100 at or past the grant, or when `unlimited: true` has no positive entitlement; 0 for an unlimited seat with a positive entitlement; null where unmeasured |
| `credits_used` | Present only when `harness` is `copilot`. The raw number in `quota_snapshots.premium_interactions.credits_used`. Null where absent, mistyped or unavailable, including a provider or stated reading. Independent of `monthly_pct` and `credits.used` |
| `unlimited` | `true` only for a seat the endpoint marks `unlimited: true` with a positive numeric `entitlement` |
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
