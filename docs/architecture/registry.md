# Community directory and account

Covers: crates/core/src/registry/, crates/core/src/registry.rs

The community directory is read like any remote: strictly, capped, and honest about staleness. Sign-in and submissions ride the same client under one credential.

## Boundaries

- All reads go through the `Fetch` trait, curl via `process::Hardened`, plain http only under `KENDEX_API`; tests inject transports. Enforced by `crates/core/tests/registry.rs`.
- Bearer calls route through `crates/core/src/registry/client.rs`: one named cross-process lock serializes login, logout and refresh rotation, and a rejected request re-takes it to clear the current credential. Enforced by `crates/core/tests/credential_lock_process.rs` and `crates/core/tests/submit_client.rs`.
- The OS credential store's service name carries the debug sandbox, keyed by name not path, and its transaction lock uses the same service-plus-endpoint identity under the real home so an XDG relocation cannot split one credential family. Enforced by `crates/core/tests/credential_lock_process.rs::production_keyring_guard_blocks_across_divergent_data_roots`.

## Invariants

1. The directory payload is re-parsed under the site's own caps, refusing structural problems whole and dropping only unusable rows. Enforced by `crates/core/tests/registry.rs::parse_refuses_malformed_and_unknown_schema` and `::parse_caps_and_drops_unusable_rows`.
2. `crates/core/src/registry/generation.rs` is the one cache mechanism: an endpoint-keyed generation written atomically under `Env::registry_cache_dir`, a failed refresh serving the last fetch as stale, and a generation the machine cannot write or delete never failing a read. Enforced by `crates/core/tests/registry.rs::network_failure_serves_the_last_fetch_as_stale` and `::etag_and_body_are_one_generation_on_disk`.
3. The identity (`crates/core/src/registry/me.rs`) has no TTL, is keyed to the sign-in the read opened under, and is forgotten on sign-in, sign-out and expiry. Enforced by `crates/core/tests/me_client/`.
4. A call that did not answer is typed by which half failed (`CallFailed`), so only a request that went out may be stood in for by a stale generation, and a refusal on this machine reaches the account surfaces as a read that failed rather than as offline. Not mechanically enforced.
5. A skills.sh hit is a lead, never an identity: the pinned shape is parsed and unusable rows dropped, an unknown shape is refused whole, an empty query asks nothing, and a name the install URL cannot carry is dropped. Enforced by `crates/core/tests/registry.rs::skillssh_parses_the_pinned_shape_and_drops_bad_rows`, `::skillssh_refuses_a_shape_it_does_not_know`, `::skillssh_empty_query_asks_nothing` and `::skillssh_refuses_names_its_install_url_cannot_carry`. That a hit installs through the same subscribe path and that `KENDEX_SKILLSSH=off` is its kill switch are not mechanically enforced.

## Decisions

- The directory has a one-hour TTL (`crates/core/src/registry/cache.rs`); the identity has none.
- Collections install through `add`, the same path as any other declaration.
