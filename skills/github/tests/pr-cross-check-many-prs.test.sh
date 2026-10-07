#!/usr/bin/env bash
# Tests for pr-cross-check over many PRs. The PR file lists, their overlaps
# and the issues built from them grow with the PR count; handed to jq as
# arguments they fail the check with "Argument list too long". The fixture
# checks 60 PRs of 500 files each, every PR sharing 250 files with its
# successor: one PR's files stay under Linux's per-argument limit (128 KiB)
# and each grown list passes macOS's whole-argv limit (1 MiB), so every
# control fails on both.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "pr-cross-check-many-prs: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "pr-cross-check-many-prs: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "pr-cross-check-many-prs: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
# shellcheck source=lib/mutant-copy.sh
. "$TEST_DIR/lib/mutant-copy.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"

PR_COUNT=60
# PR n touches file sets n-1 and n: 250 paths of about 90 characters each.
pr_args=()
for n in $(seq 1 "$PR_COUNT"); do
  pr_args+=("$n")
  gh_stub_answer "pr-view:view $n --json" "$(jq -nc --argjson n "$n" '
    def set($k): [range(250) | {path: ("src/set-\($k)/file-\(.)-" + ("x" * 60) + ".rs")}];
    {number: $n, headRefName: "b\($n)", baseRefName: "main",
     mergeable: "MERGEABLE", files: (set($n - 1) + set($n))}')"
done

# run SCRIPT — the checked PRs, the overlap issue count and the merge order,
# one per line, or the failure's stderr.
run() {
  local out
  if out="$(PATH="$TMP_ROOT/bin:$PATH" bash "$1" "${pr_args[@]}" --json 2>"$TMP_ROOT/err")"; then
    jq -r '(.prs | map(.number) | map(tostring) | join(",")),
      ([.issues[] | select(.type == "file_overlap")] | length),
      (.merge_order | map(tostring) | join(","))' <<<"$out"
  else
    cat "$TMP_ROOT/err"
  fi
}

# PR 1 and PR 60 overlap one neighbour each, the rest two: the ends go first.
want="$(seq 1 "$PR_COUNT" | paste -sd, -)
$((250 * (PR_COUNT - 1)))
1,$PR_COUNT,$(seq 2 $((PR_COUNT - 1)) | paste -sd, -)"

echo "=== 60 PRs with large, overlapping file lists ==="
assert_eq "$(run "$TEST_DIR/../scripts/commands/pr-cross-check.sh")" "$want" \
  "every PR, overlap and merge position is reported"

echo "=== must-fail controls: one list passed as a jq argument ==="
# sites[i]: the stdin line froms[i] becomes tos[i], which hands one list over
# as an argument.
sites=(merge-order overlap-issues result)
froms=(
  "    printf '%s\\n%s\\n' \"\$prs_json\" \"\$overlaps_json\" | jq -s '"
  "    issues=\$(printf '%s\\n%s\\n' \"\$issues\" \"\$overlaps\" | jq -s '.[0] + ("
  "    result=\$(printf '%s\\n%s\\n%s\\n' \"\$prs_data\" \"\$issues\" \"\$merge_order\" | jq -s \\"
)
tos=(
  "    { printf '%s\\n' \"\$prs_json\"; jq -n --argjson o \"\$overlaps_json\" '\$o'; } | jq -s '"
  "    issues=\$({ printf '%s\\n' \"\$issues\"; jq -n --argjson o \"\$overlaps\" '\$o'; } | jq -s '.[0] + ("
  "    result=\$(jq -n --argjson p \"\$prs_data\" --argjson i \"\$issues\" --argjson m \"\$merge_order\" '\$p, \$i, \$m' | jq -s \\"
)
for i in 0 1 2; do
  site="${sites[$i]}"
  mutant="$(mutant_copy_edit "$TMP_ROOT/$site" "${froms[$i]}" "${tos[$i]}" commands/pr-cross-check.sh)"
  got="$(run "$mutant")"
  case "$got" in
  *"Argument list too long"*) assert_eq argv-limit argv-limit "control $site: the argument route fails" ;;
  *) assert_eq "$got" "Argument list too long" "control $site: the argument route fails" ;;
  esac
done

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
