- **Breaking:** the `pre-commit-check` hook reads words, not shell, and needs
  `jq`. Bash's metacharacters split words here too, so a no-verify flag, an `-n`
  cluster or a `core.hooksPath` key refuses.
