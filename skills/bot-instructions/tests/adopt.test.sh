#!/usr/bin/env bash
# `adopt`, the marker gate, and the write phase.
#
# `render` refuses to replace a file at a generated path that does not carry
# this package's marker — the rule that stops it destroying hand-written bot
# files. `adopt` is the verb that makes an unmanaged thing managed, printing
# what it took over so the diff shows the content that has to survive in the
# TOML.

. "$(dirname "$0")/lib/harness.sh"

repo="$(bi_new_repo adopt)"

# A repo arriving with hand-written bot files.
mkdir -p "$repo/.github/instructions" "$repo/.github"
cat > "$repo/.github/copilot-instructions.md" <<'EOF'
# fixture

Review rules for this repository. Our full policy is in
[the review guide](REVIEW-GUIDE.md) and the path rules are described in
`.github/REVIEWERS.md`.

[handbook]: HANDBOOK.md

Never flag the generated parser as unformatted.
EOF
cat > "$repo/.github/instructions/tests.instructions.md" <<'EOF'
---
applyTo: "src/tests/**"
---

Hand-written: a test that shells out is deliberate here.
EOF
printf 'guide\n' > "$repo/REVIEW-GUIDE.md"
printf 'reviewers\n' > "$repo/.github/REVIEWERS.md"
printf 'handbook\n' > "$repo/HANDBOOK.md"
git -C "$repo" add -A >/dev/null 2>&1

# `render` refuses before `adopt` has run: those files are the repo's own.
expect_message "run \`adopt\` to take it over" \
  'render refuses an unmarked file at a generated path' render --repo "$repo"

bi_run adopt --repo "$repo"
for want in ".github/copilot-instructions.md" \
            ".github/instructions/tests.instructions.md" \
            "AGENTS.md § Code Review Rules"; do
  if printf '%s\n' "$bi_out" | grep -qF "adopted $want"; then
    ok "adopt names what it took over: $want"
  else
    bad "adopt names what it took over: $want" "$bi_out"
  fi
done

# `adopt` also names every repo-root or `.github/` markdown file an adopted
# file points at. That second list is where a repo-wide hand-written reviewer
# file shows up: a claim in one of those that the TOML does not carry is about
# to be deleted, or to go on steering reviews from outside the package.
#
# Three pointer forms, one level, no recursion: an inline link's target, a
# reference definition's target, and a backticked path. Following prose
# mentions would make the report unbounded and two implementations would
# disagree on the set.
for want in "REVIEW-GUIDE.md" ".github/REVIEWERS.md" "HANDBOOK.md"; do
  if printf '%s\n' "$bi_out" | grep -qF "points at $want"; then
    ok "adopt names a markdown file the adopted content points at: $want"
  else
    bad "adopt names a markdown file the adopted content points at: $want" "$bi_out"
  fi
done

# The bytes survive the adoption: what the file held is still there, and the
# diff against the next render is what the TOML has to absorb.
if grep -q 'Never flag the generated parser' "$repo/.github/copilot-instructions.md"; then
  ok 'an adopted file keeps its bytes and gains the marker'
else
  bad 'an adopted file keeps its bytes and gains the marker'
fi

expect_green 'render then replaces what adopt took over' render --repo "$repo"
expect_green 'and the repo checks clean' check --repo "$repo"

bi_run adopt --repo "$repo"
if printf '%s\n' "$bi_out" | grep -q 'nothing to adopt'; then
  ok 'a second adopt says there is nothing to adopt'
else
  bad 'a second adopt says there is nothing to adopt' "$bi_out"
fi

# A hand-written file in a scanned directory under a name no surface produces
# is left alone, which is correct and stays the repo's own.
repo="$(bi_new_repo adopt-untouched)"
mkdir -p "$repo/.github/instructions"
printf 'the repo wrote this\n' > "$repo/.github/instructions/ours.instructions.md"
bi_run adopt --repo "$repo"
if [ "$bi_status" -ne 0 ]; then
  bad 'a file under a name no surface produces is left alone' "adopt exited $bi_status"
elif ! printf '%s\n' "$bi_out" | grep -q 'adopted AGENTS.md'; then
  # The positive half: adopt has to have taken SOMETHING over, or leaving one
  # file alone says nothing about whether it looked.
  bad 'a file under a name no surface produces is left alone' 'adopt took nothing over'
elif grep -q 'the repo wrote this' "$repo/.github/instructions/ours.instructions.md"; then
  ok 'a file under a name no surface produces is left alone'
else
  bad 'a file under a name no surface produces is left alone'
fi

# --- the write phase --------------------------------------------------------
# A failure part way through leaves the manifest, so re-running `render`
# finishes the set. What the design does not claim is an atomic multi-file
# replacement: no filesystem offers one, and a mixed tree that says so beats
# one that does not.
repo="$(bi_rendered_repo adopt-manifest)" || exit 1
mkdir -p "$repo/.bot-instructions"
printf '{"pending": [".coderabbit.yaml", ".pr_agent.toml"]}\n' \
  > "$repo/.bot-instructions/render-manifest.json"
bi_run render --repo "$repo"
if printf '%s\n' "$bi_out" | grep -q 'earlier render left a manifest'; then
  ok 'a render finding a manifest says it is finishing an earlier set'
else
  bad 'a render finding a manifest says it is finishing an earlier set' "$bi_out"
fi
if [ ! -f "$repo/.bot-instructions/render-manifest.json" ]; then
  ok 'a completed render clears its manifest'
else
  bad 'a completed render clears its manifest'
fi

# The write re-reads `AGENTS.md` and locates the owned region in those bytes,
# so a region that stopped being this package's between the build and the
# write fails naming the path rather than overwriting it.
repo="$(bi_rendered_repo adopt-region)" || exit 1
python3 - "$repo/AGENTS.md" <<'PY'
import sys
p = sys.argv[1]
lines = [l for l in open(p).read().split("\n") if "generated by bot-instructions" not in l]
open(p, "w").write("\n".join(lines))
PY
expect_message "run \`adopt\` to take it over" \
  'a region whose marker went missing is not overwritten' render --repo "$repo"

# A symlink at a generated path is never followed and never replaced: the
# containment rule is about the open rather than about the write.
repo="$(bi_rendered_repo adopt-symlink)" || exit 1
rm -f "$repo/.pr_agent.toml"
ln -s /etc/hostname "$repo/.pr_agent.toml"
expect_message "is a symlink" 'a symlink at a generated path is refused, not followed' \
  render --repo "$repo"

bi_summary
