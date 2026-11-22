# Repair a broken `.agents` entry

Run when a worktree's `.agents` entry is broken. Route by shape, not by whether `test -L .agents` passes.

1. Ask both indexes what sits under the path: `git -C <worktree> ls-files -- '.agents/'`, and the same command against the main checkout.
   - The trailing slash is the query. Descendants decide the layout, and the entry itself does not count.
   - Neither index alone decides.
2. Repair by the answers:
   - **Either non-empty.** The repo commits its render, and `.agents` is a REAL DIRECTORY by design: the tracked files, plus one symlink per untracked child, except an untracked `.gitignore`, which is a copy of main's file.
     - A child missing its link, or a real path where a link belongs, is `fix-links`.
     - A modified or corrupt TRACKED file is `git checkout -- <path>`, run in the checkout the file really lives in: the main checkout when the path sits under a configured symlink, the worktree otherwise.
   - **Both empty.** The entry is untracked-only and must itself be a symlink.
     - `fix-links` is the repair.
     - With no tracked content at the path, `git checkout -- .agents` changes nothing while the link stays broken.

Run `.agents/skills/worktree/scripts/worktree fix-links <ID|PATH>` from the main checkout, naming the target. A non-zero exit names the paths it did not restore. Until they are restored, that tree is not trustworthy for local verification.

`fix-links --help` gives the routing table and link mechanics.
