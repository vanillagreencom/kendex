#!/usr/bin/env bash
# Outbound's tracker patterns, literal regions, representation and metadata
# lifetime. Discovery uses processes in fixture checkouts, never live APIs.
# Each independent skip/metadata rule has its own mutant. Sorting the Linear
# keys has no behavioral mutant: the required trailing hyphen already prevents
# HT from matching HTIO. The prefix row holds the resulting links instead.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
sk_tracker_fixture
ROOT="$(sk_tracker_root linear Team '')"
GH="$(sk_tracker_root github '' org/repo)"
NONE="$(sk_tracker_root none '' '')"

while IFS='|' read -r label input expected; do
  sk_markup "$ROOT" outbound "$input" markdown
  assert_eq "$RC=$(jq -r '.result[0]' <<<"$OUT")" "0=$expected" "$label"
done <<'ROWS'
Linear prefix keys|HT-4 HTIO-5 KEN-7|[HT-4](https://linear.app/workspace/issue/HT-4) [HTIO-5](https://linear.app/workspace/issue/HTIO-5) [KEN-7](https://linear.app/workspace/issue/KEN-7)
identifier boundaries|xKEN-1 KEN-x UNKNOWN-2 KEN-1x|xKEN-1 KEN-x UNKNOWN-2 KEN-1x
empty input||
Markdown labels and URLs|[KEN-1](https://example.test/KEN-2)|[KEN-1](https://example.test/KEN-2)
nested link label|[item [KEN-1]](https://example.test/a_(KEN-2))|[item [KEN-1]](https://example.test/a_(KEN-2))
inline code|`KEN-1` and ``KEN-2 ` KEN-3``|`KEN-1` and ``KEN-2 ` KEN-3``
bare URL|https://example.test/KEN-1|https://example.test/KEN-1
bare www URL|www.example.test/KEN-1|www.example.test/KEN-1
reference link|[KEN-1][item]|[KEN-1][item]
reference definition|[KEN-1]: https://example.test/KEN-2|[KEN-1]: https://example.test/KEN-2
ROWS
# Slack angle tokens contain pipes, so these shaped rows use a tab separator.
while IFS=$'\t' read -r label input; do
  sk_markup "$ROOT" outbound "$input" markdown
  assert_eq "$RC=$(jq -r '.result[0]' <<<"$OUT")" "0=$input" "$label"
done <<'ROWS'
Slack link	<https://linear.app/workspace/issue/KEN-1|KEN-1>
Slack date	<!date^1^{time}|KEN-1>
Slack mention	<@KEN-1>
ROWS
for fence in '```' '~~~~'; do
  TEXT="$(printf '%s\nKEN-1\n%s\nKEN-2' "$fence" "$fence")"
  sk_markup "$ROOT" outbound "$TEXT" markdown
  assert_eq "$RC=$(jq -r '.result[0]' <<<"$OUT")" "0=${TEXT%KEN-2}[KEN-2](https://linear.app/workspace/issue/KEN-2)" "fenced code $fence stays literal, following text links"
done
sk_markup "$ROOT" outbound $'```\nKEN-1' markdown
assert_eq "$RC=$(jq -r '.result[0]' <<<"$OUT")" $'0=```\nKEN-1' 'an open fence stays literal'
sk_markup "$ROOT" outbound 'KEN-1' file
assert_eq "$RC=$(jq -r '.result | join(" ")' <<<"$OUT")" '0=<https://linear.app/workspace/issue/KEN-1|KEN-1> text' 'file comments take mrkdwn'
LONG="$(python3 -c 'print("x " * 5980 + "KEN-1", end="")')"
sk_markup "$ROOT" outbound "$LONG" markdown
assert_eq "$RC=$(jq -r '.result[1]' <<<"$OUT")=$(jq -r '.result[0] | endswith("<https://linear.app/workspace/issue/KEN-1|KEN-1>")' <<<"$OUT")" '0=text=true' 'expansion selects mrkdwn before rendering'
sk_markup "$GH" outbound '#2 org/other#3 KEN-1 x#4' markdown
assert_eq "$RC=$(jq -r '.result[0]' <<<"$OUT")" '0=[#2](https://github.com/org/repo/issues/2) [org/other#3](https://github.com/org/other/issues/3) KEN-1 x#4' 'GitHub local and qualified issues use their own repositories'
sk_markup "$NONE" outbound 'KEN-1 #2' markdown
assert_eq "$RC=$(jq -c '[.result[0],.notices]' <<<"$OUT")" '0=["KEN-1 #2",[]]' 'no tracker leaves text unchanged without notice'
# One process sees every root independently, even while a Linear cache is warm.
sk_markup "$ROOT" roots "$ROOT" "$GH" "$NONE"
assert_eq "$RC=$(jq -c '.result' <<<"$OUT")" '0=["[KEN-1](https://linear.app/workspace/issue/KEN-1) #2 org/other#3","KEN-1 [#2](https://github.com/org/repo/issues/2) [org/other#3](https://github.com/org/other/issues/3)","KEN-1 #2 org/other#3"]' 'one process selects each root tracker'
: > "$ROOT/linear.calls"
sk_markup "$ROOT" lifetime refresh
assert_eq "$RC=$(jq -r '.result.reads | join(",")' <<<"$OUT")" '0=1,1,1,2,2' 'metadata reads once then refreshes at one day'
BEFORE='[HTIO-5](https://linear.app/workspace/issue/HTIO-5) NEW-6'
AFTER='HTIO-5 [NEW-6](https://linear.app/workspace/issue/NEW-6)'
assert_eq "$RC=$(jq -r '.result.texts | join(";")' <<<"$OUT")" "0=$BEFORE;$BEFORE;$BEFORE;$AFTER;$AFTER" 'cached keys stay linked until expiry, then refreshed keys link'

# Real producers can fail or return incomplete JSON; no stale links survive.
for fixture in exit json slug keys item empty; do
  BROKEN="$(sk_tracker_root "broken-$fixture" Team '')"
  case "$fixture" in
    exit) printf '1\n' > "$BROKEN/linear.exit" ;;
    json) printf 'not-json\n' > "$BROKEN/linear.json" ;;
    slug) printf '{"urlKey":"bad/url","keys":["KEN"]}\n' > "$BROKEN/linear.json" ;;
    keys) printf '{"urlKey":"workspace","keys":"KEN"}\n' > "$BROKEN/linear.json" ;;
    item) printf '{"urlKey":"workspace","keys":["bad"]}\n' > "$BROKEN/linear.json" ;;
    empty) printf '{"urlKey":"workspace","keys":[]}\n' > "$BROKEN/linear.json" ;;
  esac
  sk_markup "$BROKEN" lifetime
  assert_eq "$RC=$(jq -r '[(.result.reads | join(",")), (.result.texts | unique | join(" ")), (.notices | length), (.notices[0] | startswith("slack: tracker-links-unavailable="))] | join(" ")' <<<"$OUT")" '0=1,1,1,2,2 HTIO-5 1 true' "failed $fixture read stays unlinked and notices once"
  if [ "$fixture" = exit ]; then
    assert_has "$OUT" "cause=$SK_LINEAR_STUB/scripts/linear.sh exit=1" 'failed exit read names the subprocess and status'
  fi
done

# One mutation per skip zone, preserving the matching input.
while IFS='|' read -r zone input; do
  [ "$zone" != fence ] || input=$'~~~\nKEN-1\n~~~'
  sk_mutant "skip-$zone" markup.py "    \"$zone\": [^\n]*\n" ''
  sk_markup "$ROOT" outbound "$input" markdown
  assert_has "$OUT" '[KEN-1](https://linear.app/workspace/issue/KEN-1)' "control: removing $zone makes its literal id link"
  sk_bin_reset
done <<'ROWS'
markdown|[KEN-1](https://example.test/item)
angle|<@KEN-1>
url|https://example.test/KEN-1
code|`KEN-1`
fence|fenced
ROWS
sk_mutant cache markup.py 'now - cached\[0\] < METADATA_SECONDS' 'now - cached[0] < 0'
: > "$ROOT/linear.calls"
sk_markup "$ROOT" lifetime refresh
assert_eq "$RC=$(jq -r '.result.reads | join(",")' <<<"$OUT")" '0=1,2,3,4,5' 'control: without cache lifetime every call reads'
sk_bin_reset
sk_mutant expiry markup.py 'now - cached\[0\] < METADATA_SECONDS' 'True'
: > "$ROOT/linear.calls"
sk_markup "$ROOT" lifetime refresh
assert_eq "$RC=$(jq -r '.result.reads | join(",")' <<<"$OUT")" '0=1,1,1,1,1' 'control: without expiry metadata never refreshes'
assert_eq "$RC=$(jq -r '.result.texts | join(";")' <<<"$OUT")" "0=$BEFORE;$BEFORE;$BEFORE;$BEFORE;$BEFORE" 'control: without expiry refreshed keys never link'
sk_bin_reset
sk_mutant warning markup.py 'if root not in self.warned:' 'if True:'
sk_markup "$SK_TMP/broken-exit" lifetime
assert_eq "$RC=$(jq -r '.notices | length' <<<"$OUT")" '0=2' 'control: without notice deduplication failure repeats its notice'
sk_bin_reset
sk_mutant status markup.py 'if proc.returncode != 0:' 'if False:'
sk_markup "$SK_TMP/broken-exit" lifetime
assert_lacks "$OUT" "cause=$SK_LINEAR_STUB/scripts/linear.sh exit=1" 'control: ignoring exit status loses the failed-exit baseline cause'
sk_bin_reset
sk_mutant slug markup.py 'if not isinstance\(slug, str\) or re.fullmatch\(r"\[a-zA-Z0-9_\-\]\+", slug\) is None:' 'if False:'
sk_markup "$SK_TMP/broken-slug" outbound 'KEN-1' markdown
assert_has "$OUT" 'https://linear.app/bad/url/issue/KEN-1' 'control: without slug validation a bad URL is linked'
sk_bin_reset
sk_mutant keys markup.py 'if not isinstance\(keys, list\) or not keys or any\(' 'if False and any('
sk_markup "$SK_TMP/broken-keys" outbound 'K-1' markdown
assert_has "$OUT" '[K-1](https://linear.app/workspace/issue/K-1)' 'control: without key array validation a string becomes individual keys'
sk_bin_reset
sk_mutant empty markup.py 'or not keys or any\(' 'or any('
sk_markup "$SK_TMP/broken-empty" outbound '-1' markdown
assert_eq "$RC=$(jq -r '.notices | length' <<<"$OUT")" '0=0' 'control: an empty metadata array is accepted without its notice'
sk_bin_reset
sk_mutant cap markup.py 'len\(markdown\) > MARKDOWN_LIMIT' 'input_size > MARKDOWN_LIMIT'
sk_markup "$ROOT" outbound "$LONG" markdown
assert_eq "$RC=$(jq -r '.result[1]' <<<"$OUT")" '0=markdown_text' 'control: measuring input alone misses expansion across the cap'
sk_bin_reset
sk_mutant item markup.py 're.fullmatch\(r"\[A-Z\]\[A-Z0-9\]\*", key\) is None' 'False'
sk_markup "$SK_TMP/broken-item" outbound 'bad-1' markdown
assert_has "$OUT" '[bad-1](https://linear.app/workspace/issue/bad-1)' 'control: without key grammar validation malformed keys link'
sk_bin_reset
sk_mutant file-form markup.py 'mrkdwn = file_comment or' 'mrkdwn = False or'
sk_markup "$ROOT" outbound 'KEN-1' file
assert_eq "$RC=$(jq -r '.result[1]' <<<"$OUT")" '0=markdown_text' 'control: without file representation rule a file comment takes Markdown'
sk_bin_reset
sk_mutant team markup.py 'if team:' 'if False:'
sk_markup "$ROOT" outbound 'KEN-1' markdown
assert_eq "$RC=$(jq -r '.result[0]' <<<"$OUT")" '0=KEN-1' 'control: without team selection a Linear id stays bare'
sk_bin_reset
sk_mutant roots markup.py 'cached = self.cache.get\(root\)' 'cached = next(iter(self.cache.values()), None)'
sk_markup "$ROOT" roots "$ROOT" "$GH"
assert_eq "$RC=$(jq -r '.result[1]' <<<"$OUT")" '0=[KEN-1](https://linear.app/workspace/issue/KEN-1) #2 org/other#3' 'control: without per-root cache selection GitHub uses Linear metadata'
sk_bin_reset
sk_mutant linear-boundary markup.py 're.compile\(r"\\b\(\?:"' 're.compile(r"(?:"'
sk_markup "$ROOT" outbound 'xKEN-1' markdown
assert_eq "$RC=$(jq -r '.result[0]' <<<"$OUT")" '0=x[KEN-1](https://linear.app/workspace/issue/KEN-1)' 'control: without the Linear boundary an embedded id links'
sk_bin_reset
sk_mutant github-boundary markup.py '\(\?<!\[\\w/#\]\)' ''
sk_markup "$GH" outbound 'x#2' markdown
assert_eq "$RC=$(jq -r '.result[0]' <<<"$OUT")" '0=x[#2](https://github.com/org/repo/issues/2)' 'control: without the GitHub boundary an embedded id links'
sk_bin_reset
sk_summary
