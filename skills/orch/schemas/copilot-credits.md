# Copilot credit record

Read when a pick, a roster line or a lane's account names a Copilot pool. The record is one account's monthly AI credit pool. Agent-runtime's account listing reads it from GitHub's usage endpoint with the account's stored login. `emit` in [`listing.rs`](../../agent-runtime/runtime/src/accounts/listing.rs) and `parse_copilot` in [`usage.rs`](../../agent-runtime/runtime/src/accounts/usage.rs) own the record.

An account is a Copilot CLI home, read through its `config.json` login or the Secret Service item that login names. It can also be a Pi root on a `github-copilot/` model, read through its `auth.json` entry. A provider's `accounts` row reads a pool as `harness=copilot` or `harness=pi` ([lane-host.md § Provider protocol](lane-host.md#provider-protocol)). Where neither the login nor a provider row answers, the account's `AGENT_RUNTIME_COPILOT_POOL` entry states the pool.

## Where it is

- `orch-runtime lane roster` prints one record per account at `result.rows[].record`.
- `orch-runtime lane pick --fleet --harness copilot` replies `{answer, exit, record}`. `--lane <dir>` judges that one account.
- Each account's endpoint answer is kept in one usage record, `usage/copilot-<cksum of the account dir>-<its length>.json` under `AGENT_RUNTIME_ACCOUNT_STATE_DIR`.
- Every reader on the machine serves a figure younger than `AGENT_RUNTIME_USAGE_TTL` seconds, or than a caller's longer `AGENT_RUNTIME_USAGE_MAX_AGE`. [settings.md § Accounts](../references/settings.md#accounts) explains a TTL of `0`. For the usage defaults, see `AccountSettings::read_except_retirements` in [the agent-runtime settings](../../agent-runtime/runtime/src/settings.rs). The same file's `account_state_dir` supplies the records root default.

`lane pick`'s `record`, by `answer`:

| `answer` | `record` |
|---|---|
| `lane` for the chosen account; `walled`, `reserved`, `retired`, `excluded`, `unmeasured` or `cloud-repo-unset` for a named one | That account's record, with the judge's `word`, `claims` and `wall` beside it. |
| `unmeasured`, for a model no account bills | `{harness, model}`. |
| `none` | The counts of the accounts that did not qualify. |
| `unjudged` | Its `cause`. |

## Fields

| Field | Meaning |
|---|---|
| `harness` | `copilot`, or `pi` for a Pi root's pool. |
| `config_dir` | The account: the Copilot CLI home or the Pi root. |
| `alias` | The account's label: its `AGENT_RUNTIME_ACCOUNT_ALIASES` entry, else the directory's name without its leading dot. |
| `measured_through` | `local` for this machine's read, `host` for a provider's `accounts` row, `stated` for an `AGENT_RUNTIME_COPILOT_POOL` reading. |
| `status` | `ok` or `rate_limited` where measured. `no_credentials` where no login was read, with `detail` naming why. `no_usage_data` where the answer measured nothing. `refused`, `unreachable` or `error` for a failed read. |
| `monthly_pct` | The share of the grant used, in whole percent rounded up: 100 at or past the grant, whatever overage the account permits; 0 where more remains than was granted, and for an unlimited seat; 100 where the endpoint says unlimited with no positive entitlement; null where unmeasured. |
| `unlimited` | `true` only for a seat the endpoint marks `unlimited: true` with a positive numeric `entitlement`. |
| `headroom_pct` | 100 minus `monthly_pct`; null where unmeasured. |
| `binding_bucket`, `binding_resets_at`, `resets.monthly` | `monthly`, and the pool's reset in ISO 8601 UTC: the endpoint's `quota_reset_date_utc`, or a provider row's `monthly-resets`. All three are null where unmeasured. The reset is null for a stated reading and wherever no date is given. |
| `usage_age_s` | Seconds since the endpoint answered the served figure. |
| `credits_used` | The endpoint's raw `quota_snapshots.premium_interactions.credits_used`, on a `copilot` or `pi` record. It is null where absent or not a number, and on a provider or stated reading. Judge nothing by it: `monthly_pct` and `credits.used` come from `entitlement` and `remaining`. |
| `credits` | The counts ([§ Credits](#credits)); null where unmeasured. |

## Credits

`credits` on a counted pool:

| Field | Meaning |
|---|---|
| `unit` | `AIC`, AI credits. |
| `unlimited` | `false`. |
| `used` | `entitlement` less `remaining`; `monthly_pct` is judged from it. A stated reading gives the stated used. |
| `granted` | The monthly grant, `entitlement`. A stated reading gives the stated grant. |
| `remaining` | The endpoint's `remaining`. A stated reading gives the grant less the used, never below 0. |
| `over`, `overage_permitted`, `token_based_billing` | The endpoint's `overage_count`, `overage_permitted` and `token_based_billing`; absent on a stated reading. `overage_permitted` gives a pool at its grant no room. |
| `measured_at` | When the listing read the figure, in ISO 8601 UTC. |

An unlimited seat's `credits` is `{unit: "AIC", unlimited: true, measured_at}`. A provider row's record takes `monthly_pct` from the row's `monthly-pct` and carries no `credits`.
