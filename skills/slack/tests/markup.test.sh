#!/usr/bin/env bash
# Outbound's tracker patterns, literal regions, representation and metadata
# lifetime. Discovery uses processes in fixture checkouts, never live APIs.
# Each independent skip/metadata rule has its own mutant. Sorting the Linear
# keys has no behavioral mutant: the required trailing hyphen already prevents
# HT from matching HTIO. The prefix row holds the resulting links instead.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

# Only these rows run for the raw-fallback control. Payload capture uses the
# production Slack serializer and RootRelay, without opening a network socket.
continuation_cases() {
  local root
  root="$(sk_tracker_root "payloads-${1:-all}-${SK_PASS}" Team '')" || return 1
  env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    SLACK_ORCH_DIR="$SK_ROOT/skills/orch" SLACK_LINEAR_DIR="$SK_LINEAR_STUB" \
    PYTHONPATH="${SK_BIN%/*}/lib" python3 - "$root" "${1:-all}" <<'PY'
import json, re, sys, urllib.parse
from pathlib import Path
from api import Slack
from markup import Verbatim, outbound
from refusals import Refusal
from relay import RootRelay
from settings import Presence, Settings
from store import Binding, Journal, READ, compact, format_at, read_journal, write_binding

base, mode = Path(sys.argv[1]), sys.argv[2]
now = 1800000000
settings = Settings('fixture', '', ['owner@example.test'], 1, 7, 'https://fixture.invalid')

class Capture(Slack):
    def __init__(self):
        super().__init__('fixture', settings.api_url)
        self.requests, self.messages = [], []
        self.failure = None
    def _open(self, req, label, read=None):
        body = json.loads(req.data) if req.data else dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(req.full_url).query))
        self.requests.append((label, body))
        if label == 'chat.postMessage':
            if self.failure and len(self.messages) == 1:
                failure, self.failure = self.failure, None
                raise failure
            ts = str(now + len(self.messages) + 1) + '.000000'
            self.messages.append(dict(body, ts=ts, bot_id='B001', text=body.get('markdown_text', body.get('text', ''))))
            answer = {'ok': True, 'ts': ts}
        elif label == 'conversations.history':
            answer = {'ok': True, 'messages': [m for m in self.messages if 'thread_ts' not in m]}
        elif label == 'conversations.replies':
            answer = {'ok': True, 'messages': [m for m in self.messages if m['ts'] == body['ts'] or m.get('thread_ts') == body['ts']]}
        elif label.startswith('reactions.'):
            answer = {'ok': True}
        else:
            raise AssertionError(label)
        return json.dumps(answer).encode()

def root(name, api=None):
    path = base / name
    path.mkdir()
    # The native reader-generation command reads the fixture's overseer.
    (path / '.agents').symlink_to(base / '.agents', target_is_directory=True)
    (path / 'tmp').mkdir()
    (path / 'tmp/workflow-state-oversee.json').write_text('{"overseer":{"generation":0}}')
    (path / 'linear.json').write_bytes((base / 'linear.json').read_bytes())
    write_binding(path, Binding('C001', 'fixture', str(now), settings.owners, {settings.owners[0]: 'U001'}))
    return RootRelay(path, settings, Presence('', 600), api or Capture(), lambda: now + 100)

def envelope(name, text=''):
    return {'id': name, 'at': format_at(now), 'from': 'overseer', 'text': text}

def payloads(api):
    return [body for method, body in api.requests if method == 'chat.postMessage']

def content(parts):
    if len(parts) == 1:
        return parts[0]['markdown_text']
    return ''.join(p['markdown_text'].split('\n\n', 1)[1] for p in parts)

def checked(api, expected, thread=None):
    parts = payloads(api)
    assert parts
    for i, part in enumerate(parts):
        assert 'markdown_text' in part and 'text' not in part and 'blocks' not in part
        assert len(part['markdown_text']) <= 12000
        if len(parts) > 1:
            assert re.findall(r'[0-9]+', part['markdown_text'].split('\n\n', 1)[0]) == [str(i + 1), str(len(parts))]
        assert part.get('thread_ts') == (thread if thread else None if i == 0 else api.messages[0]['ts'])
    assert content(parts) == expected
    return parts

# Final linked sizes are independent of the splitter's own limit constant.
link = '[KEN-1](https://linear.app/workspace/issue/KEN-1)'
for size in (11999, 12000, 12001):
    body = '# Section\n\n**Decision** KEN-1\n\n- one\n- two\n\n'
    expanded = body.replace('KEN-1', link)
    body += 'z' * (size - len(expanded))
    expected = expanded + 'z' * (size - len(expanded))
    relay = root('size-' + str(size))
    relay.post_notice(envelope('size', body))
    parts = checked(relay.api, expected)
    assert len(parts) == (1 if size <= 12000 else 2)
    assert relay.state.carried == {'size'} and not relay.state.progress
    print(json.dumps({'final_chars': size, 'payloads': [{'fields': sorted(p), 'chars': len(p['markdown_text']), 'thread_ts': p.get('thread_ts')} for p in parts]}))

relay = root('expansion')
body = '# Report\n\n' + 'word ' * 2390 + 'KEN-1'
assert len(body) < 12000 < len(body.replace('KEN-1', link))
relay.post_notice(envelope('expanded', body))
checked(relay.api, body.replace('KEN-1', link))
assert outbound(relay.path, body, fallback=False) == (body.replace('KEN-1', link), 'markdown_text')

relay = root('thread')
body = '# First\n\n' + 'a ' * 7500 + '\n\n# Second\n\n' + 'b ' * 7500
thread = '1799999999.000000'
relay.journal.append(t='parent', ts=thread, parent={'ts': thread, 'author': 'owner', 'excerpt': 'context'})
relay.journal.append(t='in', channel='C001', ts=str(now), kind='directive', id='owner', thread=thread, generation=0)
relay.post_notice(dict(envelope('thread', body), ref='owner'))
checked(relay.api, body, thread)
assert relay.state.by_envelope['thread'] == thread
assert relay.state.threads[thread].kind == 'parent'

if mode == 'representation':
    sys.exit(0)

# Whole-envelope validation precedes every write, even across a future split.
relay = root('secret')
relay.post_notice(envelope('secret', 'p' * 11985 + ' xoxb-' + '0123456789abcdefghij'))
assert not payloads(relay.api) and relay.state.refused == {'secret': 'secret-value'}

# Drafts use the existing Verbatim renderer, retaining literal tracker ids,
# angle tokens and embedded backtick fences in independently closed parts.
for name, draft in [('literal', 'Hello <https://example.invalid|Reset> & KEN-123 `x`\n' + 'y' * 24000),
                    ('backticks', 'run ```make```\n' + 'y' * 24000)]:
    relay = root(name)
    relay._send(envelope(name), 'ask', [Verbatim(draft, name)], None)
    fragments = []
    for part in payloads(relay.api):
        assert 'text' not in part and len(part['markdown_text']) <= 12000
        rendered = part['markdown_text'].split('\n\n', 1)[1]
        fence, inner = rendered.split('\n', 1)
        assert set(fence) == {'`'} and len(fence) >= 3
        assert inner.endswith(fence)
        fragments.append(inner[:-len(fence)])
    # Nonfinal fence fragments add one wrapper newline; the original
    # Verbatim renderer adds one before its final closing fence.
    restored = ''.join(fragment[:-1] for fragment in fragments)
    assert restored == draft

relay = root('authored-fence')
body = '```python\n' + 'print(1)\n' * 4000 + '```\n'
relay._send(envelope('code'), 'notice', body, None)
fragments = []
for part in payloads(relay.api):
    rendered = part['markdown_text'].split('\n\n', 1)[1]
    assert rendered.startswith('```python\n') and rendered.endswith('```\n')
    fragments.append(rendered[len('```python\n'):-len('```\n')])
assert ''.join(fragment[:-1] if i < len(fragments) - 1 else fragment for i, fragment in enumerate(fragments)) == 'print(1)\n' * 4000

# Upload comments keep their supported mrkdwn path and upload lifecycle.
relay = root('upload')
file = relay.path / 'report.md'
file.write_text('report')
uploads = []
relay.api.upload = lambda *args: uploads.append(args) or 'F001'
relay.post_notice(dict(envelope('upload', 'KEN-1'), attach=str(file)))
assert uploads[0][3] == '<https://linear.app/workspace/issue/KEN-1|KEN-1>'
assert relay.state.pending_files == {'F001': 'upload'} and not payloads(relay.api)

# An accepted prefix then a known refusal remains eligible after restart.
# Catch-up discovers the partial root as a generic parent; terminal completion
# must promote that same object before an owner reply is classified.
relay = root('recovery')
ask = dict(envelope('ask', '# Question\n\n' + 'q' * 24000),
           options=['yes', 'no'], recommend='no', deadline=format_at(now + 300))
relay.api.failure = Refusal('slack-api-failed', 'fixture', error='internal_error')
assert not relay.post_ask(ask)
assert len(relay.api.messages) == 1 and 'ask' not in relay.state.carried
api = relay.api
compact(relay.path, now - 1)
assert read_journal(relay.path).progress['ask']['next'] == 1
relay = RootRelay(relay.path, settings, Presence('', 600), api, lambda: now + 100)
relay.catch_up('UBOT', set())
ts = api.messages[0]['ts']
parent = relay.state.threads[ts]
assert parent.kind == 'parent' and not parent.open
# These existing generation marks belong to that same discovered root.
relay.journal.append(t='in', channel='C001', ts=str(now + 2), kind='directive', id='prior', thread=ts, generation=0)
relay.journal.append(t='mark', ts=str(now + 2), name=READ)
reads = dict(parent.reads)
context = dict(parent.parent)
assert relay.post_ask(ask)
assert parent is relay.state.threads[ts] and parent.kind == 'ask' and parent.open
assert parent.envelope == 'ask' and parent.reads == reads and relay.state.marks[str(now + 2)] == READ
assert all(parent.parent[key] == value for key, value in context.items())
assert parent.parent['envelope'] == 'ask'
assert not relay.state.progress
parts = payloads(api)
# One rejected suffix is captured too; accepted parts remain ordered once.
assert parts[1] == parts[2]
accepted = [dict(m) for m in api.messages]
assert all(m.get('thread_ts') == ts for m in accepted[1:])
assert len({m['markdown_text'] for m in accepted}) == len(accepted)
assembled = content(accepted)
assert assembled.count(ask['text']) == 1 and '<@U001>' in assembled
for option in ask['options']:
    assert assembled.index(option) > assembled.index(ask['text'])
assert '<!date^1800000300^' in assembled
class Mail:
    def __init__(self): self.answers = []
    def answer(self, *args): self.answers.append(args); return 'answered', 'answer'
relay._mail = Mail()
relay.handle({'ts': str(now + 50), 'thread_ts': ts, 'user': 'U001', 'text': 'yes'}, 'UBOT')
assert relay.mail.answers == [('ask', 'yes', 'C001:' + str(now + 50))]
assert relay.state.delivered[str(now + 50)] == 'answer'
compact(relay.path, now - 1)
assert not read_journal(relay.path).progress and read_journal(relay.path).threads[ts].kind == 'ask'

# Final acknowledgement can survive a stop before the ordinary outcome.
relay = root('finalize')
item = envelope('finalize', 'f' * 12001)
ts = relay._send(item, 'notice', item['text'], None)
assert relay.state.progress['finalize']['next'] == len(relay.api.messages)
count = len(payloads(relay.api))
relay = RootRelay(relay.path, settings, Presence('', 600), relay.api, lambda: now + 100)
relay.post_notice(item)
assert len(payloads(relay.api)) == count and relay.state.by_envelope['finalize'] == ts

# A changed suffix refuses rather than splicing or repeating accepted text.
relay = root('changed')
relay.api.failure = Refusal('slack-unreachable', 'fixture')
relay.post_notice(envelope('changed', 'c' * 12001))
count = len(payloads(relay.api))
relay.post_notice(envelope('changed', 'd' * 12001))
assert len(payloads(relay.api)) == count and relay.state.refused['changed'] == 'continuation-changed'

# A lost suffix response and a stop after synced inflight both remain unknown.
for name, failure in [('unknown', Refusal('slack-response-lost', 'fixture')), ('inflight', None)]:
    relay = root(name)
    item = envelope(name, 'u' * 12001)
    if failure:
        relay.api.failure = failure
        relay.post_notice(item)
    else:
        class Interrupted(Journal):
            def append(self, **line):
                super().append(**line)
                if line.get('state') == 'inflight' and self.state.progress:
                    raise OSError('fixture stop')
        relay.journal = Interrupted(relay.path, relay.state)
        try: relay.post_notice(item)
        except OSError: pass
        else: raise AssertionError('stop did not happen')
    count = len(payloads(relay.api))
    relay = RootRelay(relay.path, settings, Presence('', 600), relay.api, lambda: now + 100)
    assert name in relay.state.unknown and name in relay.state.carried
    relay.post_notice(item)
    assert len(payloads(relay.api)) == count
print('continuation payloads and recovery: pass')
PY
}

if [ "${1:-}" = --continuations ]; then
  continuation_cases
  exit "$?"
fi
continuation_cases || exit 1
ok 'production Markdown payloads preserve content, thread order, literals and recovery'
sk_mutant raw-fallback markup.py 'mrkdwn = file_comment' 'mrkdwn = file_comment or len(markdown) > MARKDOWN_LIMIT'
if continuation_cases representation >"$SK_TMP/raw-fallback.out" 2>&1; then
  bad 'control: raw Markdown fallback must fail the payload contract'
else
  ok 'control: raw Markdown fallback fails the payload contract'
fi
sk_bin_reset
ROOT="$(sk_tracker_root linear Team '')"
GH="$(sk_tracker_root github '' org/repo)"
NONE="$(sk_tracker_root none '' '')"
printf '1\n' > "$NONE/linear.exit"

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
assert_eq "$RC=$(jq -r '.result[1]' <<<"$OUT")=$(jq -r '.result[0] | endswith("[KEN-1](https://linear.app/workspace/issue/KEN-1)")' <<<"$OUT")" '0=markdown_text=true' 'expansion retains standard Markdown for relay continuations'
sk_markup "$GH" outbound '#2 org/other#3 KEN-1 x#4' markdown
assert_eq "$RC=$(jq -r '.result[0]' <<<"$OUT")" '0=[#2](https://github.com/org/repo/pull/2) [org/other#3](https://github.com/org/other/pull/3) [KEN-1](https://linear.app/workspace/issue/KEN-1) x#4' 'GitHub PRs and workspace ids link without a team'
sk_markup "$NONE" outbound 'KEN-1 #2' markdown
assert_eq "$RC=$(jq -c '[.result[0], (.notices | length)]' <<<"$OUT")=$(printf '%s\n' "$ERR" | grep -c '^slack: tracker-links-unavailable=')" '0=["KEN-1 #2",0]=1' 'failed workspace discovery leaves ids unchanged with one stderr notice'
# One process sees every root independently, even while a Linear cache is warm.
sk_markup "$ROOT" roots "$ROOT" "$GH" "$NONE"
assert_eq "$RC=$(jq -c '.result' <<<"$OUT")" '0=["[KEN-1](https://linear.app/workspace/issue/KEN-1) #2 [org/other#3](https://github.com/org/other/pull/3)","[KEN-1](https://linear.app/workspace/issue/KEN-1) [#2](https://github.com/org/repo/pull/2) [org/other#3](https://github.com/org/other/pull/3)","KEN-1 #2 [org/other#3](https://github.com/org/other/pull/3)"]' 'one process selects workspace keys independently for each root'
: > "$ROOT/linear.calls"
sk_markup "$ROOT" lifetime refresh
assert_eq "$RC=$(jq -r '.result.reads | join(",")' <<<"$OUT")" '0=1,1,1,2,2' 'metadata reads once then refreshes at one day'
BEFORE='[HTIO-5](https://linear.app/workspace/issue/HTIO-5) NEW-6'
AFTER='HTIO-5 [NEW-6](https://linear.app/workspace/issue/NEW-6)'
assert_eq "$RC=$(jq -r '.result.texts | join(";")' <<<"$OUT")" "0=$BEFORE;$BEFORE;$BEFORE;$AFTER;$AFTER" 'cached keys stay linked until expiry, then refreshed keys link'

# Repeated relay posts share repository discovery, including a failed gh read.
for cache in original no-cache no-expiry; do
  case "$cache" in
    no-cache) sk_mutant repository-cache markup.py 'cached = self.repositories.get\(root\)' 'cached = None' ;;
    no-expiry) sk_mutant repository-expiry markup.py '(cached = self.repositories.get\(root\)\n        now = self.clock\(\)\n        if cached is not None and )now - cached\[0\] < METADATA_SECONDS' '\1True' ;;
  esac
  for fixture in success exit; do
    REPOSITORY="$(sk_tracker_root "repository-$cache-$fixture" '' org/repo)"
    PREVIOUS='[#2](https://github.com/org/repo/pull/2)'
    if [ "$fixture" = exit ]; then
      printf '1\n' > "$REPOSITORY/github.exit"
      PREVIOUS='#2'
    fi
    REFRESHED='[#2](https://github.com/org/changed/pull/2)'
    sk_markup "$REPOSITORY" lifetime github refresh
    GOT="$RC=$(jq -r '[(.result.reads | join(",")), (.result.texts | join(";"))] | join(" ")' <<<"$OUT")"
    WANT="0=1,1,1,2,2 $PREVIOUS;$PREVIOUS;$PREVIOUS;$REFRESHED;$REFRESHED"
    if [ "$cache" = original ]; then
      assert_eq "$GOT" "$WANT" "repository $fixture discovery stays cached until expiry, then refreshes"
    else
      sk_assert_red "$GOT" "$WANT" "control: repository $fixture lifetime fails with $cache"
    fi
  done
  sk_bin_reset
done

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
  assert_eq "$RC=$(jq -r '[(.result.reads | join(",")), (.result.texts | unique | join(" ")), (.notices | length)] | join(" ")' <<<"$OUT")=$(printf '%s\n' "$ERR" | grep -c '^slack: tracker-links-unavailable=')" '0=1,1,1,2,2 HTIO-5 0=1' "failed $fixture read stays unlinked and warns once on stderr"
  if [ "$fixture" = exit ]; then
    assert_has "$ERR" "cause=$SK_LINEAR_STUB/scripts/linear.sh exit=1" 'failed exit read names the subprocess and status'
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
sk_mutant cache markup.py '(cached = self.cache.get\(root\)\n        if cached is not None and )now - cached\[0\] < METADATA_SECONDS' '\1now - cached[0] < 0'
: > "$ROOT/linear.calls"
sk_markup "$ROOT" lifetime refresh
assert_eq "$RC=$(jq -r '.result.reads | join(",")' <<<"$OUT")" '0=1,2,3,4,5' 'control: without cache lifetime every call reads'
sk_bin_reset
sk_mutant expiry markup.py '(cached = self.cache.get\(root\)\n        if cached is not None and )now - cached\[0\] < METADATA_SECONDS' '\1True'
: > "$ROOT/linear.calls"
sk_markup "$ROOT" lifetime refresh
assert_eq "$RC=$(jq -r '.result.reads | join(",")' <<<"$OUT")" '0=1,1,1,1,1' 'control: without expiry metadata never refreshes'
assert_eq "$RC=$(jq -r '.result.texts | join(";")' <<<"$OUT")" "0=$BEFORE;$BEFORE;$BEFORE;$BEFORE;$BEFORE" 'control: without expiry refreshed keys never link'
sk_bin_reset
sk_mutant warning markup.py 'if root not in self.warned:' 'if True:'
sk_markup "$SK_TMP/broken-exit" lifetime
assert_eq "$RC=$(printf '%s\n' "$ERR" | grep -c '^slack: tracker-links-unavailable=')" '0=2' 'control: without notice deduplication failure repeats its notice'
sk_bin_reset
sk_mutant status markup.py 'if proc.returncode != 0:' 'if False:'
sk_markup "$SK_TMP/broken-exit" lifetime
assert_lacks "$ERR" "cause=$SK_LINEAR_STUB/scripts/linear.sh exit=1" 'control: ignoring exit status loses the failed-exit baseline cause'
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
assert_eq "$RC=$(printf '%s\n' "$ERR" | grep -c '^slack: tracker-links-unavailable=')" '0=0' 'control: an empty metadata array is accepted without its notice'
sk_bin_reset
sk_mutant item markup.py 're.fullmatch\(r"\[A-Z\]\[A-Z0-9\]\*", key\) is None' 'False'
sk_markup "$SK_TMP/broken-item" outbound 'bad-1' markdown
assert_has "$OUT" '[bad-1](https://linear.app/workspace/issue/bad-1)' 'control: without key grammar validation malformed keys link'
sk_bin_reset
sk_mutant file-form markup.py 'mrkdwn = file_comment' 'mrkdwn = False'
sk_markup "$ROOT" outbound 'KEN-1' file
assert_eq "$RC=$(jq -r '.result[1]' <<<"$OUT")" '0=markdown_text' 'control: without file representation rule a file comment takes Markdown'
sk_bin_reset
sk_mutant roots markup.py 'cached = self.cache.get\(root\)' 'cached = next(iter(self.cache.values()), None)'
sk_markup "$ROOT" roots "$ROOT" "$NONE"
assert_eq "$RC=$(jq -r '.result[1]' <<<"$OUT")" '0=[KEN-1](https://linear.app/workspace/issue/KEN-1) #2 [org/other#3](https://github.com/org/other/pull/3)' 'control: without per-root cache selection a failed root uses another root workspace keys'
sk_bin_reset
sk_mutant linear-boundary markup.py 're.compile\(r"\\b\(\?:"' 're.compile(r"(?:"'
sk_markup "$ROOT" outbound 'xKEN-1' markdown
assert_eq "$RC=$(jq -r '.result[0]' <<<"$OUT")" '0=x[KEN-1](https://linear.app/workspace/issue/KEN-1)' 'control: without the Linear boundary an embedded id links'
sk_bin_reset
sk_mutant github-boundary markup.py '\(\?<!\[\\w/#\]\)' ''
sk_markup "$GH" outbound 'x/#2' markdown
assert_eq "$RC=$(jq -r '.result[0]' <<<"$OUT")" '0=x/[#2](https://github.com/org/repo/pull/2)' 'control: without the GitHub boundary an embedded id links'
sk_bin_reset

REFS="$(sk_tracker_root references Team org/kendex)"
git -C "$REFS" -c user.name=Fixture -c user.email=fixture@example.test commit --allow-empty --no-gpg-sign -qm fixture || exit 1
FULL="$(git -C "$REFS" rev-parse HEAD)" || exit 1
SHORT="${FULL:0:7}"
while IFS='|' read -r label input expected; do
  input="${input//@SHORT@/$SHORT}"; input="${input//@FULL@/$FULL}"
  expected="${expected//@SHORT@/$SHORT}"; expected="${expected//@FULL@/$FULL}"
  sk_markup "$REFS" outbound "$input" markdown
  assert_eq "$RC=$(jq -r '.result[0]' <<<"$OUT")" "0=$expected" "$label"
  case "$label" in
    'PRs under Linear') PR_INPUT="$input"; PR_EXPECTED="0=$expected" ;;
    'short and full commits') COMMIT_INPUT="$input"; COMMIT_EXPECTED="0=$expected" ;;
  esac
done <<'ROWS'
PRs under Linear|kendex#2 #3 KEN-1|[kendex#2](https://github.com/org/kendex/pull/2) [#3](https://github.com/org/kendex/pull/3) [KEN-1](https://linear.app/workspace/issue/KEN-1)
short and full commits|@SHORT@ @FULL@|[@SHORT@](https://github.com/org/kendex/commit/@FULL@) [@FULL@](https://github.com/org/kendex/commit/@FULL@)
every mention|kendex#2 kendex#2 @SHORT@ @SHORT@|[kendex#2](https://github.com/org/kendex/pull/2) [kendex#2](https://github.com/org/kendex/pull/2) [@SHORT@](https://github.com/org/kendex/commit/@FULL@) [@SHORT@](https://github.com/org/kendex/commit/@FULL@)
literal references|`kendex#2` `@SHORT@` [kendex#2](https://example.test/pr)|`kendex#2` `@SHORT@` [kendex#2](https://example.test/pr)
unresolved references|unknown#2 deadbeef unknown#2 deadbeef|unknown#2 deadbeef unknown#2 deadbeef
ROWS
# The relay and post logs consume this keyed diagnostic; English text is unpinned.
assert_eq "$(printf '%s\n' "$ERR" | grep -c '^slack: reference-link-unavailable=')" '2' 'one stderr warning per unresolved reference'
assert_has "$ERR" 'reference-link-unavailable=unknown#2 ' 'unknown repo warning identifies its input'
assert_has "$ERR" 'reference-link-unavailable=deadbeef ' 'missing commit warning identifies its input'
sk_markup "$REFS" outbound "kendex#2 $SHORT" file
assert_eq "$RC=$(jq -r '.result | join(" ")' <<<"$OUT")" "0=<https://github.com/org/kendex/pull/2|kendex#2> <https://github.com/org/kendex/commit/$FULL|$SHORT> text" 'PRs and commits render as file comment links'
# Two real Git objects share a prefix, so a hash cannot identify either one.
AMBIGUOUS="$(python3 - "$REFS" <<'PY'
import hashlib, os, subprocess, sys
env = {key: os.environ[key] for key in ("PATH", "HOME", "LANG") if key in os.environ}
algorithm = subprocess.run(["git", "rev-parse", "--show-object-format"], cwd=sys.argv[1],
                           env=env, stdout=subprocess.PIPE, text=True, check=True).stdout.strip()
seen = {}
for number in range(65537):
    data = str(number).encode()
    prefix = hashlib.new(algorithm, b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()[:4]
    if prefix in seen:
        for body in (seen[prefix], data):
            subprocess.run(["git", "hash-object", "-w", "--stdin"], cwd=sys.argv[1], input=body,
                           env=env, stdout=subprocess.PIPE, check=True)
        objects = subprocess.run(["git", "rev-parse", "--disambiguate=" + prefix], cwd=sys.argv[1],
                                 env=env, stdout=subprocess.PIPE, text=True, check=True).stdout.splitlines()
        if len(objects) < 2:
            sys.exit("ambiguity fixture: fewer than two Git objects")
        print(prefix)
        break
    seen[prefix] = data
else:
    sys.exit(1)
PY
)" || exit 1
sk_markup "$REFS" outbound "$AMBIGUOUS $AMBIGUOUS" markdown
assert_eq "$RC=$(jq -r '.result[0]' <<<"$OUT")" "0=$AMBIGUOUS $AMBIGUOUS" 'ambiguous hash stays literal at every mention'
assert_eq "$(printf '%s\n' "$ERR" | grep -c '^slack: reference-link-unavailable=')" '1' 'ambiguous hash reports one stderr warning'
sk_mutant pr-link markup.py 'target = f"https://github.com/\{repo\}/pull/\{number\}"' 'target = None'
sk_markup "$REFS" outbound "$PR_INPUT" markdown
sk_assert_red "$RC=$(jq -r '.result[0]' <<<"$OUT")" "$PR_EXPECTED" 'control: current bare PR form fails the linked result'
sk_bin_reset
sk_mutant commit-link markup.py 'target = f"https://github.com/\{repo\}/commit/\{commit\}"' 'target = None'
sk_markup "$REFS" outbound "$COMMIT_INPUT" markdown
sk_assert_red "$RC=$(jq -r '.result[0]' <<<"$OUT")" "$COMMIT_EXPECTED" 'control: removing commit links fails the linked result'
sk_bin_reset
sk_summary
