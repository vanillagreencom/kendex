# The directory is read like any remote

Read before changing the community directory, sign-in, submissions or the skills.sh lead.

## The approach

The community directory at kendex.ai is read strictly, capped, and honestly about staleness. Every read goes through the client in `crates/core/src/registry/`, over curl through the hardened process constructor, with the payload re-parsed under the site's own caps. One cache mechanism, the generation file, serves a failed refresh the last fetch as stale. Sign-in, submissions and refresh rotation ride the same client under one credential family, serialized by one named cross-process lock.

## Why

The directory is a remote, so it gets the same distrust as a catalog and the same offline behaviour as a mirror: a structural problem refuses the payload whole, an unusable row is dropped, and a network failure is reported as stale, never as empty. One credential family under one lock is what keeps two processes from rotating each other's token.

## Rules

- Do refuse a malformed or unknown-schema payload whole and drop only unusable rows.
- Do serve the last generation as stale on a failed refresh, and never fail a read because the machine cannot write its cache.
- Do type a call that did not answer by which half failed, as `CallFailed` in `crates/core/src/registry/client.rs` does, so only a request that went out may be stood in for by a stale generation.
- Do treat a skills.sh hit as a lead, never an identity: it installs through the same subscribe path as any reference, and `KENDEX_SKILLSSH=off` is its kill switch.
- Do keep the directory's time to live where `crates/core/src/registry/cache.rs` sets it, and revalidate past it with a conditional request.
- Never carry a credential outside the OS store's service, which carries the debug sandbox in its name so a sandboxed build cannot read the real one.

## The canonical example

`crates/core/src/registry/generation.rs`: one endpoint-keyed generation written atomically and read back on failure, with `crates/core/tests/registry.rs` planting the network failure and the malformed payload. A new endpoint reads through it.

## Revisit when

The directory gains an endpoint whose answer cannot be served stale, such as a payment or a one-time token, or a second credential family appears that the one lock cannot serialize.

## Not governed

What the directory itself lists and how it ranks: the kendex.ai site. How a subscription found through it is read: [sources.md](sources.md).
