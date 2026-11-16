# Copilot credit record

Read when a pick, a roster line or a lane's account names a Copilot pool. The record is one account's monthly AI credit pool as agent-runtime's account listing reads it from GitHub's usage endpoint with the account's stored login. [`listing.rs`](../../agent-runtime/runtime/src/accounts/listing.rs) owns the endpoint, the login reads and the record's shape (`emit`); `parse_copilot` in [`usage.rs`](../../agent-runtime/runtime/src/accounts/usage.rs) owns the rules for zero, overage and unlimited.

An account is a Copilot CLI home, read through its `config.json` login or the Secret Service item that login names, or a Pi root on a `github-copilot/` model, read through its `auth.json` entry. A provider's `accounts` row reads a pool as `harness=copilot` or `harness=pi` ([lane-host.md § Provider protocol](lane-host.md#provider-protocol)). Where neither the login nor a provider row answers, an `AGENT_RUNTIME_COPILOT_POOL` entry for the account states the pool.

## Where it is

- `orch-runtime lane roster` prints one record per account at `result.rows[].record`.
- `orch-runtime lane pick --fleet --harness copilot` replies `{answer, exit, record}`, and `--lane <dir>` judges that one account. Where `answer` names an account's verdict (`lane` for the chosen account, or `walled`, `reserved`, `retired`, `excluded`, `unmeasured`, `cloud-repo-unset` for a named one), `record` is that account's record with the judge's fields beside it (`word`, `claims`, `wall`); an `unmeasured` answer for a model no account bills carries `{harness, model}` instead; `none` carries the counts of the accounts that did not qualify, and `unjudged` its `cause`.
- The endpoint's answer is kept in one usage record per account, `usage/copilot-<cksum of the account dir>-<its length>.json` under `AGENT_RUNTIME_ACCOUNT_STATE_DIR`, which defaults to `kendex/agent-runtime/accounts` under `XDG_STATE_HOME`, else under `~/.local/state`. Every reader on the machine serves a figure younger than `AGENT_RUNTIME_USAGE_TTL` seconds (default 300), or a caller's longer `AGENT_RUNTIME_USAGE_MAX_AGE`; a TTL of 0 serves none. A record that does not parse, or names another account, is a miss, and the account is measured again ([`cache.rs`](../../agent-runtime/runtime/src/accounts/cache.rs)).

## Fields

| Field | Meaning |
|---|---|
| `harness` | `copilot`, or `pi` for a Pi root's pool |
| `config_dir` | The account: the Copilot CLI home, or the Pi root |
| `alias` | The account's label: its `AGENT_RUNTIME_ACCOUNT_ALIASES` entry, else the directory's name without its leading dot |
| `measured_through` | `local` for this machine's read, `host` for a provider's `accounts` row, `stated` for an `AGENT_RUNTIME_COPILOT_POOL` reading |
| `status` | `ok` or `rate_limited` where measured; `no_credentials` where no login was read, with `detail` naming the reason (`config-missing`, `config-unreadable`, `token-missing`, `token-ambiguous`, `token-foreign-host`, or for a Secret Service login `keyring-absent`, `keyring-locked`, `keyring-refused`, `keyring-empty`); `no_usage_data` where the answer measured nothing; `refused`, `unreachable` or `error` for a failed read |
| `monthly_pct` | Share of the grant used, whole percent rounded up: 100 at or past the grant whatever overage the account permits, 0 where more remains than was granted, 0 for an unlimited seat, 100 where the endpoint says unlimited with no positive entitlement; null where unmeasured |
| `unlimited` | `true` only for a seat the endpoint marks `unlimited: true` with a positive numeric `entitlement` |
| `headroom_pct` | 100 minus `monthly_pct`; null where unmeasured |
| `binding_bucket`, `binding_resets_at`, `resets.monthly` | `monthly`, and the pool's reset in ISO 8601 UTC from the endpoint's `quota_reset_date_utc`, or a provider row's `monthly-resets`. All null where unmeasured; the reset is null for a stated reading and wherever no date is given |
| `usage_age_s` | Seconds since the endpoint answered the figure served |
| `credits_used` | The endpoint's raw `quota_snapshots.premium_interactions.credits_used`, on a `copilot` or `pi` record; null where absent or not a number, and on a provider or stated reading. Judge nothing by it: `monthly_pct` and `credits.used` are computed from `entitlement` and `remaining` |
| `credits` | The counts, § Credits; null where unmeasured |

## Credits

`credits` on a counted pool:

| Field | Meaning |
|---|---|
| `unit` | `AIC`, AI credits |
| `unlimited` | `false` |
| `used` | `entitlement` less `remaining`, the figure `monthly_pct` is judged from; for a stated reading, the stated used |
| `granted` | The monthly grant, `entitlement`; for a stated reading, the stated grant |
| `remaining` | The endpoint's `remaining`; for a stated reading, the grant less the used, never below 0 |
| `over`, `overage_permitted`, `token_based_billing` | The endpoint's `overage_count`, `overage_permitted` and `token_based_billing`; absent on a stated reading. `overage_permitted` gives a pool at its grant no room |
| `measured_at` | When the figure was read, ISO 8601 UTC |

`credits` on an unlimited seat is `{unit: "AIC", unlimited: true, measured_at}`. A provider row's record takes `monthly_pct` from the row's `monthly-pct` and carries no `credits`.
