#!/usr/bin/env bash
# Scope pins. Each mode decides which lines the line-scoped lanes may speak
# about, so a mode that quietly widens or narrows its diff would either fail
# innocent changes or wave real ones through. docs-cited-paths is the vehicle
# throughout: one added line, one finding, in a file every mode can reach.
# Environment failures (bad flag, no repository, unresolvable base) must exit
# 2 — distinct from a clean run and from a run with findings.
#
# Every row pins the WHOLE fired set, so "in scope" and "out of scope" are one
# claim: a mode that widened its diff by one file reddens the row that named
# the narrower set, with no separate absence assertion to keep in step.
#
# The diff-parse hardening this file used to carry is `diff-parse.test.sh`.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A workflow that runs one named suite: the runner input the unwired-suite
# lane reads out of whichever scope is under test.
runner_names() { # SUITE — write $R/.github/workflows/ci.yml naming it
  mkdir -p "$R/tests" "$R/.github/workflows"
  printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash %s\n' \
    "$1" >"$R/.github/workflows/ci.yml"
}

# A settings file declaring one env value, at a path the scope rules decide
# whether to honour.
settings_at() { # PATH KEY VALUE — write $R/PATH
  mkdir -p "$(dirname "$R/$1")"
  printf '[env]\n%s = "%s"\n' "$2" "$3" >"$R/$1"
}

JSONC_GLOB='**/themes/*/apps/vscode-theme.json'

# One world per row: every state a case used to reach by evolving the fixture
# under it is its own word, seeded and planted from scratch, so no row depends
# on the row before it.
pf_world() {
  # The two worlds that are not repositories at all. Both runs start outside
  # the path they name, which is what `--repo` has to reach on its own.
  case "$1" in
    not-a-repo)
      R="$TMP/not-a-repo"
      rm -rf -- "${TMP:?}/not-a-repo"
      mkdir -p "$R"
      PF_CWD="$TMP"
      return 0
      ;;
    no-such-directory)
      R="$TMP/no-such-directory"
      rm -rf -- "${TMP:?}/no-such-directory"
      PF_CWD="$TMP"
      return 0
      ;;
  esac
  pf_scope_seed "$1"
  case "$1" in
    # One dead citation staged, another only in the worktree: the two scopes
    # disagree about the second, and each row's fired set says which it saw.
    staged)
      printf '# Staged\n\nSee `docs/gone.md` for the rest.\n' >"$R/docs/staged.md"
      git -C "$R" add docs/staged.md
      printf '# Loose\n\nSee `docs/gone.md` too.\n' >"$R/docs/loose.md"
      ;;
    # A staged suite AND the staged workflow edit that wires it, with the
    # worktree workflow restored to the old name: a lane reading the worktree
    # would call the staged suite unwired.
    staged-runner | worktree-runner)
      runner_names tests/other.test.sh
      git -C "$R" add -A
      git -C "$R" commit -qm ci
      printf '#!/usr/bin/env bash\nset -euo pipefail\necho new\n' >"$R/tests/new.test.sh"
      runner_names tests/new.test.sh
      git -C "$R" add -A
      runner_names tests/other.test.sh
      # The inverse: a second staged suite only the WORKTREE workflow names.
      if [ "$1" = worktree-runner ]; then
        printf '#!/usr/bin/env bash\nset -euo pipefail\necho new2\n' >"$R/tests/new2.test.sh"
        git -C "$R" add tests/new2.test.sh
        runner_names tests/new2.test.sh
      fi
      ;;
    # The same index rule covers a lane's policy inputs. A staged JSONC
    # declaration governs the staged theme; the worktree copy that narrows it
    # does not. The inverse world closes the bypass the other way round.
    staged-jsonc | worktree-jsonc)
      mkdir -p "$R/themes/white/apps"
      printf '{\n  // staged JSONC\n  "name": "white",\n}\n' >"$R/themes/white/apps/vscode-theme.json"
      settings_at kendex.settings.toml PREFLIGHT_JSONC_GLOBS "$JSONC_GLOB"
      git -C "$R" add themes/white/apps/vscode-theme.json kendex.settings.toml
      settings_at kendex.settings.toml PREFLIGHT_JSONC_GLOBS ""
      if [ "$1" = worktree-jsonc ]; then
        git -C "$R" add kendex.settings.toml
        settings_at kendex.settings.toml PREFLIGHT_JSONC_GLOBS "$JSONC_GLOB"
      fi
      ;;
    # New shared settings do not exist in the commit. Neither supported shared
    # path may widen JSONC during a staged run; the control is the same world
    # with no settings file at all.
    untracked-jsonc-control | untracked-root-jsonc | untracked-nested-jsonc)
      mkdir -p "$R/themes/white/apps"
      printf '{\n  // remains strict without a committed setting\n  "name": "white"\n}\n' \
        >"$R/themes/white/apps/vscode-theme.json"
      git -C "$R" add themes/white/apps/vscode-theme.json
      case "$1" in
        untracked-root-jsonc) settings_at kendex.settings.toml PREFLIGHT_JSONC_GLOBS "$JSONC_GLOB" ;;
        untracked-nested-jsonc) settings_at .kendex/settings.toml PREFLIGHT_JSONC_GLOBS "$JSONC_GLOB" ;;
      esac
      ;;
    # Nor may either narrow the migration set out from under the same run.
    untracked-root-migration | untracked-nested-migration)
      printf 'CREATE TABLE t (id INTEGER, name TEXT);\n' >"$R/store/migrations/V1__init.sql"
      git -C "$R" add store/migrations/V1__init.sql
      case "$1" in
        untracked-root-migration) settings_at kendex.settings.toml PREFLIGHT_MIGRATION_GLOBS "" ;;
        untracked-nested-migration) settings_at .kendex/settings.toml PREFLIGHT_MIGRATION_GLOBS "" ;;
      esac
      ;;
    # An untracked file is a new file to the default scope and nothing at all
    # to --staged; an ignored one is nothing to either.
    untracked)
      printf '# Never added\n\nSee `docs/gone.md` here too.\n' >"$R/docs/never-added.md"
      mkdir -p "$R/scratch"
      printf 'scratch/\n' >"$R/.gitignore"
      printf '# Ignored\n\nSee `docs/gone.md` from an ignored file.\n' >"$R/scratch/ignored.md"
      ;;
    # A new doc under a new directory is judged as it will be once committed:
    # its citation of a missing sibling fires even though nothing tracked
    # lives in that directory yet.
    newdir)
      mkdir -p "$R/docs/new"
      printf '# New\n\nSee `docs/new/missing.md`.\n' >"$R/docs/new/guide.md"
      ;;
    # The worktree has moved on past the index: --staged judges the staged
    # bytes, so the finding sits on the staged line.
    rewound)
      printf '# Staged\n\nSee `docs/gone.md` for the rest.\n' >"$R/docs/staged.md"
      git -C "$R" add docs/staged.md
      printf '# Staged\n\nAll clean again.\n' >"$R/docs/staged.md"
      ;;
    # Untouched: the default scope has nothing, --all has every tracked line,
    # including the citation the baseline committed.
    everything) ;;
    # A commit made on the branch, for the rows that name their own base and
    # for the row that reaches the repository from outside it.
    based | repo-relocate)
      printf '# Loose\n\nSee `docs/gone.md` from this commit.\n' >"$R/docs/loose.md"
      git -C "$R" add -A
      git -C "$R" commit -qm "add a citation"
      if [ "$1" = repo-relocate ]; then PF_CWD="$TMP"; fi
      ;;
    # The default base walk, one world per state of the fallback chain:
    # origin/HEAD, then origin/main, then the local main, then nothing.
    base-origin-head | base-origin-main | base-local-main | base-none)
      printf '# Loose\n\nSee `docs/gone.md` once more.\n' >"$R/docs/loose.md"
      git -C "$R" add -A
      case "$1" in
        base-origin-head) ;;
        base-origin-main) git -C "$R" remote set-head origin --delete >/dev/null ;;
        base-local-main)
          git -C "$R" remote set-head origin --delete >/dev/null
          git -C "$R" update-ref -d refs/remotes/origin/main
          ;;
        base-none)
          git -C "$R" remote set-head origin --delete >/dev/null
          git -C "$R" update-ref -d refs/remotes/origin/main
          git -C "$R" branch -q -D main
          ;;
      esac
      ;;
    *)
      printf 'pf_world: no such world: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

# `read -d ''` rather than `$(cat <<'ROWS' ...)`: Bash 3.2 scans a here-document
# inside a command substitution for quotes, and a row carrying an odd number
# of double quotes runs its parse past the closing parenthesis. It returns 1
# at the end of the document, which errexit must not read; an empty table is
# pf_table's refusal.
#
# `says` carries only what a row cannot be told apart without: an environment
# error's message, and a clean verdict whose changed-file count is the claim.
IFS= read -r -d '' rows <<'ROWS' || :
the staged dead citation fires and the unstaged one is out of scope|staged|--staged|-|1|docs/staged.md:3: [docs-cited-paths]|-
the default scope is base-to-worktree, so it sees both|staged|-|-|1|docs/loose.md:3: [docs-cited-paths];docs/staged.md:3: [docs-cited-paths]|-
the staged runner wires the staged suite, whatever the worktree copy says|staged-runner|--staged|-|0|-|-
a worktree-only mention does not wire a staged suite|worktree-runner|--staged|-|1|tests/new2.test.sh:0: [unwired-suite]|-
a staged JSONC setting governs the staged file despite a narrower worktree copy|staged-jsonc|--staged|jq|0|-|-
a worktree-only JSONC setting cannot widen the staged policy|worktree-jsonc|--staged|jq|1|themes/white/apps/vscode-theme.json:2: [data-syntax]|invalid JSON
control: staged JSON stays strict before a shared JSONC setting exists|untracked-jsonc-control|--staged|jq|1|themes/white/apps/vscode-theme.json:2: [data-syntax]|invalid JSON
an untracked root settings file cannot widen staged JSONC policy|untracked-root-jsonc|--staged|jq|1|themes/white/apps/vscode-theme.json:2: [data-syntax]|invalid JSON
an untracked nested settings file cannot widen staged JSONC policy|untracked-nested-jsonc|--staged|jq|1|themes/white/apps/vscode-theme.json:2: [data-syntax]|invalid JSON
an untracked root settings file cannot narrow staged migration policy|untracked-root-migration|--staged|-|1|store/migrations/V1__init.sql:0: [applied-migration-edited]|-
an untracked nested settings file cannot narrow staged migration policy|untracked-nested-migration|--staged|-|1|store/migrations/V1__init.sql:0: [applied-migration-edited]|-
a non-ignored untracked file is in scope; an ignored one is not|untracked|-|-|1|docs/never-added.md:3: [docs-cited-paths]|-
--staged sees only the index, so the untracked file is out of scope|untracked|--staged|-|0|-|-
an untracked doc in an untracked directory has its dead citation reported|newdir|-|-|1|docs/new/guide.md:3: [docs-cited-paths]|cites a path that does not exist: docs/new/missing.md
content comes from the index, so line 3 is the staged line|rewound|--staged|-|1|docs/staged.md:3: [docs-cited-paths]|-
an untouched branch has nothing in the default scope|everything|-|-|0|-|preflight: clean (0 changed file(s))
--all reaches the committed violation the default scope ignores|everything|--all|-|1|docs/legacy.md:3: [docs-cited-paths]|changed file(s)
--base main sees the commit made on the branch|based|--base main|-|1|docs/loose.md:3: [docs-cited-paths]|-
--base HEAD compares against itself and finds nothing|based|--base HEAD|-|0|-|preflight: clean
--repo relocates the run without a cd|repo-relocate|--repo {R} --base main|-|1|docs/loose.md:3: [docs-cited-paths]|-
an unknown flag is a usage error|based|--nonsense|-|2|-|unknown argument
a --base ref that resolves to nothing is an environment error|based|--base does-not-exist|-|2|-|does not resolve to a commit
a path outside any repository is an environment error|not-a-repo|--repo {R}|-|2|-|not inside a git repository
a --repo path that does not exist is an environment error|no-such-directory|--repo {R}|-|2|-|--repo path is not a directory
origin/HEAD names the default branch|base-origin-head|-|-|1|docs/loose.md:3: [docs-cited-paths]|-
a repository whose origin/HEAD was never set falls back to origin/main|base-origin-main|-|-|1|docs/loose.md:3: [docs-cited-paths]|-
with no remote-tracking refs left, the local main branch is the last fallback|base-local-main|-|-|1|docs/loose.md:3: [docs-cited-paths]|-
with nothing left to compare against, the run fails closed instead of reporting clean|base-none|-|-|2|-|could not resolve a default diff base
ROWS
pf_table "what each scope may speak about" "$rows"

pf_summary
