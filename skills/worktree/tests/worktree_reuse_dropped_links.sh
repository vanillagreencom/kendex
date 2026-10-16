#!/usr/bin/env bash
# Surface: create --reuse after WORKTREE_SYMLINKS drops a path.
# Inputs: worktree/scripts/worktree, its lib/, github/scripts/lib/.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset WORKTREE_SETUP_CMD
export WORKTREE_DEFAULT_BRANCH=main MSYS=winsymlinks:nativestrict
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd -- "$TEST_DIR/.." && pwd -P)/scripts/worktree}"
TMP_ROOT="$(mktemp -d)" || { echo 'worktree_reuse_dropped_links: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "worktree_reuse_dropped_links: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'worktree_reuse_dropped_links: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/bin/gh"
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"
PASS=0 FAIL=0

assert_eq() {
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1)); printf 'ok: %s\n' "$3"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s expected=[%s] got=[%s]\n' "$3" "$2" "$1"
  fi
}

reuse_row() {
  local kind="$1" path="$2" root="$3" main="$3/main" wt="$3/trees/reuse" rc=0 kept="" state=""
  local record="${4:-anchored}" exclude=""
  mkdir -p "$main" "$root/foreign"
  git -C "$main" init -q -b main
  git -C "$main" config user.email test@example.com
  git -C "$main" config user.name Test
  git -C "$main" config commit.gpgsign false
  git -C "$main" config gc.auto 0
  git -C "$main" config maintenance.auto false
  printf '.env.local\nnode_modules\nui/node_modules\n' >"$main/.gitignore"
  case "$kind" in
    tracked-file|tracked-link)
      mkdir -p "$main/${path%/*}"
      printf 'main\n' >"$main/target"
      if [[ "$kind" == tracked-link ]]; then ln -s ../target "$main/$path"
      else printf 'main\n' >"$main/$path"; fi
      git -C "$main" add "$path" target
      ;;
    *) mkdir -p "$main/$path"; printf 'main\n' >"$main/$path/original" ;;
  esac
  if [[ "$kind" == tracked-dir ]]; then git -C "$main" add "$path/original"; fi
  git -C "$main" add .gitignore
  git -C "$main" commit -qm base
  git init -q --bare "$root/origin.git"
  git -C "$root/origin.git" config gc.auto 0
  git -C "$root/origin.git" config maintenance.auto false
  git -C "$main" remote add origin "$root/origin.git"
  git -C "$main" push -qu origin main
  printf 'WORKTREE_BASE_DIR="../trees"\nWORKTREE_SYMLINKS="%s"\n' "$path" >"$main/.env.local"
  (cd -- "$main" && "$WORKTREE_SCRIPT" create reuse >"$root/create.out" 2>"$root/create.err")
  if [[ "$kind" == tracked-file ]]; then
    rm -- "$wt/$path"
    git -C "$wt" update-index --no-assume-unchanged -- "$path"
    printf 'branch\n' >"$wt/$path"
    git -C "$wt" add "$path"
    git -C "$wt" commit -qm branch
    (cd -- "$main" && "$WORKTREE_SCRIPT" fix-links "$wt" >"$root/fix.out" 2>"$root/fix.err")
  elif [[ "$kind" == tracked-dir ]]; then
    # Earlier releases linked whole directories over tracked descendants.
    rm -- "$wt/$path/original"
    rmdir -- "$wt/$path"
    ln -s "$main/$path" "$wt/$path"
    git -C "$wt" update-index --assume-unchanged -- "$path/original"
  fi
  [[ -L "$wt/$path" ]] || { echo 'fixture: creation did not create a link' >&2; exit 2; }
  if [[ "$record" == bare ]]; then
    # Earlier exclude_from_worktree_index wrote this unanchored record.
    exclude="$(git -C "$wt" rev-parse --git-path info/exclude)"
    printf '%s\n' "$path" >"$exclude"
  fi
  case "$kind" in
    real) rm -- "$wt/$path"; mkdir -p "$wt/$path"; printf 'private\n' >"$wt/$path/original" ;;
    foreign) rm -- "$wt/$path"; ln -s "$root/foreign" "$wt/$path" ;;
    configured) kept="$path" ;;
  esac
  printf 'WORKTREE_BASE_DIR="../trees"\nWORKTREE_SYMLINKS="%s"\n' "$kept" >"$main/.env.local"
  case "$kind" in
    tracked-file|tracked-dir|tracked-link) printf "WORKTREE_SETUP_CMD='test -e %s'\n" "$path" >>"$main/.env.local" ;;
    *) printf "WORKTREE_SETUP_CMD='test ! -L %s && mkdir -p %s && printf setup > %s/setup'\n" "$path" "$path" "$path" >>"$main/.env.local" ;;
  esac
  (cd -- "$main" && "$WORKTREE_SCRIPT" create reuse --reuse >"$root/out" 2>"$root/err") || rc=$?
  if [[ -L "$wt/$path" ]]; then state="link:$(readlink "$wt/$path")"
  elif [[ -d "$wt/$path" && -f "$wt/$path/setup" ]]; then state="private:$(cat "$wt/$path/setup")"
  else state=missing; fi
  case "$kind" in
    stale|real)
      assert_eq "$rc" 0 "$kind $path: reuse runs setup"
      assert_eq "$(cat "$root/out")" "$wt" "$kind $path: successful path"
      assert_eq "$state" private:setup "$kind $path: setup owns a real directory"
      ;;
    foreign|configured)
      local want="$root/foreign"
      [[ "$kind" != configured ]] || want="$main/$path"
      assert_eq "$rc" 1 "$kind $path: setup refuses the link"
      assert_eq "$state" "link:$want" "$kind $path: link stays in place"
      ;;
    tracked-file|tracked-dir|tracked-link)
      local tracked="$path" want=branch
      if [[ "$kind" == tracked-dir ]]; then tracked="$path/original"; want=main; fi
      if [[ "$kind" == tracked-link ]]; then want=../target; fi
      assert_eq "$rc" 0 "$kind $path: reuse restores committed content"
      assert_eq "$(git -C "$wt" ls-files -v -- "$tracked")" "H $tracked" "$kind $path: assume-unchanged is cleared"
      if [[ "$kind" == tracked-link ]]; then
        assert_eq "$(readlink "$wt/$path")" "$want" "$kind $path: index symlink target stays"
      else
        assert_eq "$([[ ! -L "$wt/$path" ]] && cat "$wt/$tracked")" "$want" "$kind $path: index content is real"
      fi
      ;;
  esac
  [[ "$kind" != real ]] || assert_eq "$(cat "$wt/$path/original")" private "real $path: private data stays"
  case "$kind" in
    tracked-file|tracked-link) assert_eq "$(cat "$main/$path")" main "$kind $path: main data stays" ;;
    *) assert_eq "$(cat "$main/$path/original")" main "$kind $path: main data stays" ;;
  esac
  assert_eq "$(find "$root/foreign" -type f -print)" '' "$kind $path: foreign target stays empty"
}

# A consumer moves root or nested dependencies to its setup command.
for record in anchored bare; do
  for path in node_modules ui/node_modules; do
    for kind in stale real foreign configured; do
      reuse_row "$kind" "$path" "$TMP_ROOT/${record}-${kind}-${path//\//-}" "$record"
    done
  done
  for kind in tracked-file tracked-link tracked-dir; do
    reuse_row "$kind" "config/$kind" "$TMP_ROOT/${record}-${kind}" "$record"
  done
done

# Keep the ownership comparison's text but bypass its effect in a disposable
# package. The foreign-link row must reject the planted deletion.
control="$TMP_ROOT/control"
mkdir -p "$control/github/scripts"
cp -R "${WORKTREE_SCRIPT%/scripts/worktree}" "$control/worktree"
cp -R "${WORKTREE_SCRIPT%/worktree/scripts/worktree}/github/scripts/lib" "$control/github/scripts/lib"
mutant="$control/worktree/scripts/lib/links.sh"
needle='      [[ "$target" == "$PROJECT_ROOT/$path" ]] || continue'
[[ -f "$mutant" && ! -L "$mutant" && "$(grep -cF "$needle" "$mutant")" == 1 ]] || { echo 'control: mutation match is not unique' >&2; exit 2; }
awk -v needle="$needle" '{ if ($0 == needle) print "      [[ \"$target\" == \"$PROJECT_ROOT/$path\" ]] || :"; else print }' "$mutant" >"$control/changed"
cmp -s "$mutant" "$control/changed" && { echo 'control: mutation changed nothing' >&2; exit 2; }
cat "$control/changed" >"$mutant"
if (WORKTREE_SCRIPT="$control/worktree/scripts/worktree"; PASS=0; FAIL=0
    reuse_row foreign node_modules "$TMP_ROOT/must-fail"
    [[ "$FAIL" -gt 0 ]]); then
  PASS=$((PASS + 1)); echo 'ok: must-fail control rejects foreign-link deletion'
else
  FAIL=$((FAIL + 1)); echo 'FAIL: must-fail control accepted foreign-link deletion'
fi
printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
