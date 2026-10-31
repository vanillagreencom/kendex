# Repair a broken `.agents` entry

Run when a worktree's `.agents` entry is broken. Read [§ Recovering a broken `.agents` entry](../SKILL.md#recovering-a-broken-agents-entry) first.

Ask both indexes what sits under the path: `git -C <worktree> ls-files -- '.agents/'`, and the same command against the main checkout. The trailing slash is the query; descendants decide the layout and the entry itself does not count. Neither index alone decides, and both answer while the path itself is broken:

- **Either non-empty.** The repo commits its render, and `.agents` is a REAL DIRECTORY by design: the tracked files, plus one symlink per untracked child, except an untracked `.gitignore`, which is a copy of main's file. A child missing its link, or a real path where a link belongs, is `fix-links`. A modified or corrupt TRACKED file is `git checkout -- <path>`, run in the checkout the file really lives in: the main checkout when the path sits under a configured symlink, the worktree otherwise.
- **Both empty.** The entry is untracked-only and must itself be a symlink. `fix-links` is the repair; with no tracked content at the path, `git checkout -- .agents` changes nothing while the link stays broken.

Run `.agents/skills/worktree/scripts/worktree fix-links <ID|PATH>` from the main checkout naming the target; a bare invocation there is refused. A non-zero exit names the paths it did not restore, and until they are restored that tree is not trustworthy for local verification. Routing table and link mechanics: `fix-links --help`.
