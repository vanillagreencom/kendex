# Which catalog a name comes from

Owner-decided, not yet built. Small enough to land on its own; it is not part
of the problem-triage plan.

## What happens today

`vstack add --skill github`, with no catalog named, calls
`ensure_source(manifest, None)` (`engine/ops/add.rs:303`). That returns the
source called `vstack` whenever the manifest declares it — and every seeded
manifest does (`manifest/file.rs:103`) — without looking at whether that
catalog holds `github`, and without considering any catalog the user added
themselves. Resolving it then clones the default catalog from GitHub on first
use.

So a project that has already added its own catalog, containing its own
`github` skill, still downloads an unrelated repository to install from the
wrong place. This was also the second cause of the `deps_cli` hangs.

## What it should do

**Search every catalog this scope can see, and ask when more than one has the
name.** Personal and project sources both count. A single match installs
without a question; nothing found falls back to the default catalog, which is
the only case that should ever trigger a download.

The prompt only exists where there is a real ambiguity, which should be rare.

## And a qualified form

Let a name carry its catalog: `--skill vstack/github`, `--skill team/github`.
That is the escape hatch when you know exactly what you mean, and it is what
the disambiguation prompt should teach — print the qualified forms as the
choices, so the answer to "which one?" is also the syntax for next time.

**Watch the collision.** `ensure_source` already reads an `owner/repo` shape
as a *repository* to declare as a source (`add.rs:313`). `catalog/name` has
the same shape. The qualifier is resolved against **declared source names**
first, and only a name that matches no declared source is considered a repo —
otherwise adding `--skill vstack/github` would try to declare a catalog called
`vstack/github`. Cover that case with a test, both ways round.

## Where it has to hold

- The CLI (`vstack add`), including the qualified form.
- The app's add flow, which cannot show a terminal prompt — there it is a
  picker, and it must not silently choose for the user.
- The engine, so both shells get the same answer: the search and the
  ambiguity live in `crates/core`, not in either front end.

## Tests

- One catalog has the name → installs from it, no prompt, no download.
- Two catalogs have it → refuses to guess, and names both in qualified form.
- No catalog has it → falls back to the default catalog.
- `--skill vstack/github` with a declared source `vstack` → uses that source.
- `--skill owner/repo` where no source is called that → still declares the
  repository, exactly as today.
