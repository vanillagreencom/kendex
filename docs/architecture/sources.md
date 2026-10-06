# Catalogs are adversarial input

Read before changing the source store, discovery, browsing, subscriptions, bundles, unsubscribe, the drift snapshot, the community directory, sign-in, submissions or the skills.sh lead.

## The approach

Any repository holding skills is a marketplace, with no registration step, and every byte it holds is read as untrusted: through `SealedSource` in `crates/core/src/source_read.rs`, resolved against the canonical root, with symlinks refused and depth, count and byte budgets carried. A remote is mirrored once, each commit materialized into an immutable snapshot published by rename, and the full commit id is what a lock pins. Discovery reads a closed, versioned search table and yields skills only; every other kind installs from a declared kendex layout or a plugin registry.

The community directory at kendex.ai is read like any remote: strictly, capped, and honestly about staleness. Every read goes through the client in `crates/core/src/registry.rs` and its submodules, over curl through the hardened process constructor, with the payload re-parsed under the site's own caps. One cache mechanism, the generation file, serves a failed refresh the last fetch as stale. Sign-in, submissions and refresh rotation ride the same client under one credential family, serialized by one named cross-process lock.

## Why

A catalog is someone else's repository. A read that follows a symlink, a name that is a path, a frontmatter alias or a registry entry naming another repository is how that repository reaches outside itself, so each is refused at the one door every read goes through. Immutable snapshots make an install reproducible offline and make "what changed" a diff between two commits.

The directory is a remote, so it gets a catalog's distrust and a mirror's offline behaviour: a structural problem refuses the payload whole, an unusable row is dropped, and a network failure is reported as stale, never as empty. One credential family under one lock keeps two processes from rotating each other's token.

## Rules

- Do read a catalog through `SealedSource` only; a raw filesystem read in a catalog-reading module fails the `catalog-fs-read` lane of `tools/guard`.
- Do parse a subscription reference, never guess it: the two validators in `crates/core/src/source_ref.rs`, `parse_typed` for what a person types and `parse_untrusted` for untrusted rows and deep links, refuse a leading `-`, a `..` component in a repository name or URL, which a local path keeps, and a percent-escape that smuggles a separator.
- Do refuse a `kendex.toml` name that cannot be a path, with the reason, at `crates/core/src/names.rs`.
- Do fail discovery closed: a plugin registry wins outright, else a parsed control file declares the layout, else the search runs, and an unreadable control file makes the source unusable with a finding.
- Do say where a name comes from: a bare name searching every enabled subscription refuses on two offers, naming both spellings, and the default catalog is reached only when nothing else offers the name.
- Do date an offered item by the newest commit that touched what it contains, never by the bare tip.
- Never treat frontmatter as trusted YAML: aliases and duplicate keys are refused, and every interpolated value in a generated file is quoted.
- Never remove a snapshot a lock names; the keep set is the newest `KENDEX_SOURCE_CACHE_KEEP` plus every pinned commit, and a mirror is kept for the life of the install.
- Never let a bundle declaration the reader cannot read cost the other sets anything: it is reported by name and the rest installs.

### The community directory

- Do refuse a malformed or unknown-schema payload whole and drop only unusable rows.
- Do serve the last generation as stale on a failed refresh, and never fail a read because the machine cannot write its cache.
- Do read a new directory endpoint through `crates/core/src/registry/generation.rs`, one endpoint-keyed generation written atomically and read back on failure; `crates/core/tests/registry.rs` plants the network failure and the malformed payload.
- Do type a call that did not answer by which half failed, as `CallFailed` in `crates/core/src/registry/client.rs` does, so only a request that went out may be stood in for by a stale generation.
- Do treat a skills.sh hit as a lead, never an identity: it installs through the same subscribe path as any reference, and `KENDEX_SKILLSSH=off` is its kill switch.
- Do keep the directory's time to live where `crates/core/src/registry/cache.rs` sets it, and revalidate past it with a conditional request.
- Never carry a credential outside the OS store's service, which carries the debug sandbox in its name so a sandboxed build cannot read the real one.

## The canonical example

`crates/core/src/source_read.rs`: `SealedSource` is the door, and `crates/core/tests/sealed_source.rs` plants each hostile shape and watches it refused. A new reader of catalog bytes takes a `SealedSource` and nothing else.

## Revisit when

A catalog format needs a read the budgets cannot admit, such as a package larger than the byte budget, or a source kind appears that no git mirror can snapshot.

The directory gains an endpoint whose answer cannot be served stale, such as a payment or a one-time token, or a second credential family appears that the one lock cannot serialize.

## Not governed

How a snapshot is rendered into a harness: [harnesses.md](harnesses.md). What the lock records about the commit: [engine.md](engine.md). What the community directory lists and how it ranks: the kendex.ai site.
