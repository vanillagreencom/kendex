#!/usr/bin/env bash
# Shared value assertion for the skill-load-check suites.
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

# Run the suite's own row callback on a private mutant, not the whole suite.
# The subshell keeps the override and assertion counts out of the parent.
# Keep the matched code and remove only its effect.
skill_load_control() { # NAME SOURCE ANCHOR INSERT OVERRIDE ROWS FAILED-ROW...
  local name="$1" source="$2" anchor="$3" insert="$4" override="$5" rows="$6" log status row matches
  shift 6
  [ ! -L "$source" ] || { echo "skill-load-control: source=symlink" >&2; exit 2; }
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
  ' -- "$source" "$TMP_ROOT/$name.sh" "$anchor" "$insert" || exit 2
  # The caller can capture control results at a name-based path of its own.
  # Give the callback an exclusive log so those writes cannot overwrite rows.
  log=$(mktemp "$TMP_ROOT/$name.log.XXXXXX") || { echo "skill-load-control: log=mktemp-failed" >&2; exit 2; }
  set +e
  (
    set -e
    PASS=0
    FAIL=0
    printf -v "$override" '%s' "$TMP_ROOT/$name.sh"
    "$rows"
    [ "$FAIL" -eq 0 ]
  ) >"$log" 2>&1
  status=$?
  set -e
  assert_eq "$status" 1 "control $name: the mutated hook turns the suite red"
  for row in "$@"; do
    matches=$(grep -Fxc -e "  FAIL  $row" -- "$log") || {
      status=$?
      [ "$status" -eq 1 ] || { echo "skill-load-control: log=unreadable" >&2; exit 2; }
    }
    assert_eq "$matches" 1 "control $name: $row"
  done
}