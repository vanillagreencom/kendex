# The inventory is a record, never a licence

Read before changing the generated-file inventory, verification, workflow adoption or tracked outputs.

## The approach

`.kendex-generated.json` lists the files kendex wrote that verification can compare with declared content: rendered paths, plus workflow copies a package adopted with their template hash. It is the committed inventory every reader of a render path consults; a path it does not list is judged hand-written. A record there says what can be compared. It never grants permission to overwrite or restore a file: ownership comes from the positions the lock entries wrote, under [engine.md](engine.md). The one exception: an adopted workflow still at the bytes of the template its leaving package shipped leaves with that package.

## Why

CI, the commit offer, the classifier and `kendex verify` all need to know which bytes are kendex's without re-rendering. One committed list answers them. Keeping the list a record and not a licence is what stops a stale inventory, or one a branch rewrote, from authorizing a write over a person's file. The exception writes nothing and moves only bytes the leaving package's own tree vouches for, so a stale record cannot take a person's edit.

## Rules

- Do take the set from one place, `GeneratedPaths` in `crates/core/src/engine/generated_paths.rs`: written positions, adoption declarations, and held positions already listed at `HEAD`.
- Do leave a skill's top-level `tests/`, `evals/` and `DEVELOPMENT.md` out of every render; `SealedSource::rendered_item` is the one reading of which files an install holds, and an edit to one of those entries moves no hash.
- Do verify an adopted workflow against its template's bytes at the recorded revision; an edited installed template cannot attest an edited workflow, and refresh never rewrites or restores a workflow.
- Do take an adopted workflow out with its package: where the package leaves the install record and the copy still holds the bytes of the template in the package's tree, the copy goes to the trash and its record leaves the inventory; an edited copy stays, and verify keeps failing it. A tree one tool drops while the package stays is no leaving. While a retired package stays installed, its adopted workflow is held to the template in that package's tree.
- Do keep an invalid inventory's bytes: apply cannot erase an adoption declaration it could not read.
- Do read `.kendex-generated.json` at both endpoints in CI, from the render plan, with in-place sources and Pi carrier payloads outside it.
- Do keep every committed render at the bytes its source renders: `cargo test -p kendex-core --lib own_renders` plans a copy of the commit with edits discarded, fails on each inventory path a planned op would write, and names apart what the plan holds back; a hand-synced render, a render tree holding a file the render does not write, or a deleted nested `CLAUDE.md` shim would otherwise land and fail verify on `main` after the merge. The install record is the one inventory path it leaves alone, since a pull request keeps the record as `main` holds it, per [D007](../decisions/D007-lock-record-on-main.md).
- Never add a path to the inventory by hand except in a worktree, where `kendex refresh` would re-render the whole tree: there the entry is added sorted, one per line, and `cargo test -p kendex-core --lib own_inventory` judges it.
- Never treat a listed path as owned whole where `GeneratedPaths::beside` names it: the manifest, `kendex.settings.toml`, `.gitignore` and the shared edit targets are written into, never replaced.

## The canonical example

`crates/core/src/engine/generated_paths/own_inventory.rs`: it reads kendex's own committed inventory against a fresh render of the catalog and names each path that is listed and not rendered or rendered and not listed. It is the shape of every consumer of the inventory: read the list, compare, never write.
