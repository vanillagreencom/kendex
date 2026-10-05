# The directory is read like any remote

Read before changing the community directory, sign-in, submissions or the skills.sh lead.

## The approach

The community directory at kendex.ai is read strictly, capped, and honestly about staleness: every read goes through the `Fetch` trait in `crates/core/src/registry/`, over curl through the hardened process constructor, with the payload re-parsed under the site's own caps. One cache mechanism serves a failed refresh the last fetch as stale. Sign-in, submissions and refresh rotation ride the same client under one credential family, serialized by one named cross-process lock.

## Why

The directory is a remote, so it gets the same distrust as a catalog and the same offline behaviour as a mirror: a structural problem refuses the payload whole, an unusable row is dropped, and a network failure is reported as stale, never as empty. One credential family under one lock is what keeps two processes from rotating each other's token.

## Rules

- Do refuse a malformed or unknown-schema payload whole and drop only unusable rows.
- Do serve the last generation as stale on a failed refresh, and never fail a read because the machine cannot write its cache.
- Do type a call that did not answer by which half failed, so only a request that went out may be stood in for by a stale generation.
- Do treat a skills.sh hit as a lead, never an identity: it installs through the same subscribe path as any reference, and `KENDEX_SKILLSSH=off` is its kill switch.
- Never carry a credential outside the OS store's service, which carries the debug sandbox in its name so a sandboxed build cannot read the real one.
- The identity has no TTL and is forgotten on sign-in, sign-out and expiry; the directory has a one-hour TTL.

## The canonical example

`crates/core/src/registry/generation.rs`: one endpoint-keyed generation written atomically, read back on failure, and `crates/core/tests/registry.rs` plants the network failure and the malformed payload. A new endpoint reads through it.
