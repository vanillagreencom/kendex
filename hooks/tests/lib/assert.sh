#!/usr/bin/env bash
# The value assertion and the must-fail control runner the hooks suites share.
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

# Pi.scope_root emits kendex/hooks under the global Pi root. Its native
# skill copy is beside kendex; Env::global_skills_dir keeps shared skills
# under HOME even when PI_CODING_AGENT_DIR relocates the hook root.
reader_layout_rows() { # SOURCE PAYLOAD REFUSAL-KEY
  local source="$1" payload="$2" key="$3" mode home root library hook status line
  while IFS='|' read -r mode root library; do
    home="$TMP_ROOT/reader-layouts/$mode"
    rm -rf -- "$home"
    root="$home/$root"
    library="$home/$library/commit-guards/scripts/lib"
    hook="$root/kendex/hooks/$(basename "$source")"
    mkdir -p "${hook%/*}" "$library"
    cp -- "$source" "$hook"
    if [ "$mode" = native-copy ]; then
      cp -- "$TEST_DIR/../../skills/commit-guards/scripts/lib/command-position.sh" "$library/command-position.sh"
    else
      ln -s "$TEST_DIR/../../skills/commit-guards/scripts/lib/command-position.sh" "$library/command-position.sh"
    fi
    status=0
    printf '%s' "$payload" | env HOME="$home" PI_CODING_AGENT_DIR="$root" "$BASH_BIN" "$hook" >/dev/null 2>"$home/stderr" || status=$?
    line=""
    IFS= read -r line <"$home/stderr" || :
    assert_eq "rc=$status first=$line" "rc=2 first=$key" "$mode delivered reader"
  done <<'LAYOUTS'
native-copy|.pi/agent|.pi/agent/skills
shared-skill|.pi/agent|.agents/skills
relocated-shared|relocated/agent/root|.agents/skills
LAYOUTS
}

# Run the suite's own row callback on a private mutant, not the whole suite.
# The subshell keeps the override and assertion counts out of the parent.
# Keep the matched code and remove only its effect.
skill_load_control() { # NAME SOURCE ANCHOR INSERT OVERRIDE ROWS FAILED-ROW...
  local name="$1" source="$2" anchor="$3" insert="$4" override="$5" rows="$6" log status row matches variant target
  shift 6
  [ ! -L "$source" ] || { echo "skill-load-control: source=symlink" >&2; exit 2; }
  mkdir -p "$TMP_ROOT/hooks" || { echo "skill-load-control: scratch=unwritable" >&2; exit 2; }
  # Bash 3.2 pattern substitution over the full hook is costly. Byte offsets
  # keep the anchor literal and preserve the source outside the insertion.
  perl -e '
    use strict;
    use warnings;
    my ($source, $target, $anchor, $insert) = @ARGV;
    open my $input, "<", $source or die "skill-load-control: source=unreadable\n$!\n";
    local $/;
    $! = 0;
    my $text = <$input>;
    die "skill-load-control: source=unreadable\n$!\n" if $!;
    close $input or die "skill-load-control: source=unreadable\n$!\n";
    $text = "" unless defined $text;
    my $at = index($text, $anchor);
    die "skill-load-control: anchor=missing\n" if $at < 0;
    die "skill-load-control: anchor=ambiguous\n" if index($text, $anchor, $at + 1) >= 0;
    my $changed = $text;
    substr($changed, $at + length($anchor), 0) = "\n" . $insert;
    die "skill-load-control: mutation=unchanged\n" if $changed eq $text;
    open my $output, ">", $target or die "skill-load-control: mutation=unwritable\n$!\n";
    print {$output} $changed or die "skill-load-control: mutation=unwritable\n$!\n";
    close $output or die "skill-load-control: mutation=unwritable\n$!\n";
  ' -- "$source" "$TMP_ROOT/hooks/$name.sh" "$anchor" "$insert" || exit 2
  cp -- "$source" "$TMP_ROOT/hooks/$name.baseline.sh" || { echo "skill-load-control: baseline=unreadable" >&2; exit 2; }
  # Both copies use the hook/skill layout the caller prepares. The unchanged
  # copy must pass the same callback before a mutant failure is accepted.
  for variant in baseline mutant; do
    target="$TMP_ROOT/hooks/$name.sh"
    [ "$variant" != baseline ] || target="$TMP_ROOT/hooks/$name.baseline.sh"
    # The callback can use a name-based log. Keep this capture exclusive.
    log=$(mktemp "$TMP_ROOT/$name.$variant.log.XXXXXX") || { echo "skill-load-control: log=mktemp-failed" >&2; exit 2; }
    set +e
    (
      set -e
      PASS=0
      FAIL=0
      printf -v "$override" '%s' "$target"
      "$rows"
      [ "$FAIL" -eq 0 ]
    ) >"$log" 2>&1
    status=$?
    set -e
    if [ "$variant" = baseline ]; then
      assert_eq "$status" 0 "control $name: the unchanged copy passes the selected rows"
    else
      assert_eq "$status" 1 "control $name: the mutated hook turns the suite red"
    fi
  done
  for row in "$@"; do
    matches=$(grep -Fxc -e "  FAIL  $row" -- "$log") || {
      status=$?
      [ "$status" -eq 1 ] || { echo "skill-load-control: log=unreadable" >&2; exit 2; }
    }
    assert_eq "$matches" 1 "control $name: $row"
  done
}
