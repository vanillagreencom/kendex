# skills/

The catalog's skills, one directory per skill, each rendered under `.agents/skills/<name>/` for this repository's own install. The same render rule covers `agents/<n>.md` (one render per harness directory) and `hooks/<n>` (the harness hook directories that already track it).

- A change to a source with a tracked render lands the render in the same commit; a `tools/guard` lane checks presence, not bytes, because a render may carry an injected instructions block the source has no copy of. A source with no tracked render has nothing to land.
- Sync a render by replaying the source diff onto the render, never by copying the source file over it.
- Shell stays Bash 3.2 compatible; `tools/bash32-lint` runs in the guard.
- A test that shells out to git clears `GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` together. Under `orch/tests/` that clearing is `skills/orch/tests/lib/git-env.sh`, sourced on the line under each suite's `set -...o pipefail`.
- Every skill suite runs on the pull request and in the merge queue through `.github/workflows/skill-tests.yml`.
