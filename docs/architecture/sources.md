# Catalogs are adversarial input

Read before changing the source store, discovery, browsing, subscriptions, bundles, unsubscribe or the drift snapshot.

## The approach

Any repository holding skills is a marketplace, with no registration step, and every byte it holds is read as untrusted: through `SealedSource` in `crates/core/src/source_read.rs`, resolved against the canonical root, with symlinks refused and depth, count and byte budgets carried. A remote is mirrored once, each commit materialized into an immutable snapshot published by rename, and the full commit id is what a lock pins. Discovery reads a closed, versioned search table and yields skills only; every other kind installs from a declared kendex layout or a plugin registry.

## Why

A catalog is someone else's repository. A read that follows a symlink, a name that is a path, a frontmatter alias or a registry entry naming another repository is how that repository reaches outside itself, so each is refused at the one door every read goes through. Immutable snapshots make an install reproducible offline and make "what changed" a diff between two commits.

## Rules

- Do read a catalog through `SealedSource` only; a raw filesystem read in a catalog-reading module fails the `catalog-fs-read` lane of `tools/guard`.
- Do parse a subscription reference, never guess it: the two validators in `crates/core/src/source_ref.rs`, `parse_typed` for what a person types and `parse_untrusted` for untrusted rows and deep links, refuse a leading `-`, a `..` component and a percent-escape that smuggles a separator.
- Do refuse a `kendex.toml` name that cannot be a path, with the reason, at `crates/core/src/names.rs`.
- Do fail discovery closed: a plugin registry wins outright, else a parsed control file declares the layout, else the search runs, and an unreadable control file makes the source unusable with a finding.
- Do say where a name comes from: a bare name searching every enabled subscription refuses on two offers, naming both spellings, and the default catalog is reached only when nothing else offers the name.
- Do date an offered item by the newest commit that touched what it contains, never by the bare tip.
- Never treat frontmatter as trusted YAML: aliases and duplicate keys are refused, and every interpolated value in a generated file is quoted.
- Never remove a snapshot a lock names; the keep set is the newest `KENDEX_SOURCE_CACHE_KEEP` plus every pinned commit, and a mirror is kept for the life of the install.
- Never let a bundle declaration the reader cannot read cost the other sets anything: it is reported by name and the rest installs.

## The canonical example

`crates/core/src/source_read.rs`: `SealedSource` is the door, and `crates/core/tests/sealed_source.rs` plants each hostile shape and watches it refused. A new reader of catalog bytes takes a `SealedSource` and nothing else.

## Revisit when

A catalog format needs a read the budgets cannot admit, such as a package larger than the byte budget, or a source kind appears that no git mirror can snapshot.

## Not governed

How a snapshot is rendered into a harness: [harnesses.md](harnesses.md). What the lock records about the commit: [engine.md](engine.md).
