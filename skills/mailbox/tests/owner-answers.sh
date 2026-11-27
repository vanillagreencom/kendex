#!/usr/bin/env bash
# Surface: one-pass owner answer delivery.
# Inputs: skills/mailbox/scripts/**, skills/orch/tests/lib/assertions.sh,
# skills/mailbox/tests/lib/owner-replace.py.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
# shellcheck source=../../orch/tests/lib/assertions.sh
. "$ROOT/skills/orch/tests/lib/assertions.sh"
mkdir -p "$ROOT/tmp"
python3 - "$ROOT" "$BASH" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo, bash = Path(sys.argv[1]), sys.argv[2]
# Drive the shipped CLI with a tracker transport fixture. All mailbox writes,
# projection, author/time selection and delivery-id checks remain production.
with tempfile.TemporaryDirectory(dir=repo / 'tmp') as scratch:
    root = Path(scratch)
    source = Path(os.environ.get('MAILBOX_UNDER_TEST', repo / 'skills/mailbox'))
    scripts = root / '.agents/skills/mailbox/scripts'
    shutil.copytree(source / 'scripts', scripts)
    subprocess.run(['git', 'init', '-q', str(root)], check=True)
    for key in ('gc.auto', 'maintenance.auto'):
        subprocess.run(['git', '-C', str(root), 'config', key, '0' if key == 'gc.auto' else 'false'], check=True)
    subprocess.run(['git', '-C', str(root), '-c', 'core.hooksPath=/dev/null',
                    '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
                    'commit', '-q', '--allow-empty', '-m', 'fixture'], check=True)
    worktree = root / 'linked'
    subprocess.run(['git', '-C', str(root), 'worktree', 'add', '-q', '--detach', str(worktree)], check=True)
    for directory in (root / 'subdir', worktree / 'subdir'):
        directory.mkdir()
    env = {'PATH': os.environ['PATH'], 'HOME': str(root), 'ORCH_OWNER_EMAIL': 'owner@example.test',
           'ORCH_OWNER_ASK_LABEL': 'owner-gated', 'FIXTURE': str(root)}
    env.update({key: str(root / key) for key in ('XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME')})
    mail = [bash, str(scripts / 'lane-mail')]
    def call(*args, cwd=root):
        return subprocess.run([*mail, *args], cwd=cwd, env=env, capture_output=True, text=True, timeout=15, check=True)
    assert call('owner-answers', '--item', 'overseer').stdout == 'owner-answers: tracker=absent\n'
    tracker = root / '.agents/skills/linear/scripts/linear.sh'
    tracker.parent.mkdir(parents=True)
    tracker.write_text('''#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FIXTURE/calls"
if [[ "$1:$2" == comments:bulk-list ]]; then
  # The closes the overseer's mailbox holds when the tracker is read.
  jq -s '[.[] | select(.kind == "resolution")] | length' "$FIXTURE/tmp/lane-mail/overseer/to-lane.jsonl" \
    > "$FIXTURE/closes-at-read" 2>/dev/null || :
fi
if [[ -e "$FIXTURE/quota" ]]; then
  cat "$FIXTURE/quota" >&2
  exit 1
fi
# The Linear package's refusal of a description write to a GitHub-synced item
# (skills/linear issues.sh require_unsynced_description).
if [[ "$1:$2" == issues:update && -e "$FIXTURE/synced-$3" && " $* " == *" --description "* ]]; then
  printf 'linear: refused=synced-description issue=%s github=acme/app#7 override=--synced-description\\n' "$3" >&2
  exit 1
fi
case "$1:$2" in
  users:list) printf '[{"id":"owner","name":"Owner","email":"owner@example.test","display_name":"owner"}]\\n' ;;
  teams:keys) printf '{"urlKey":"workspace","keys":["KEN"]}\\n' ;;
  issues:list)
    if [[ -e "$FIXTURE/items" ]]; then cat "$FIXTURE/items"
    else printf '[{"id":"KEN-7","uuid":"uuid-KEN-7","description":"Body","assignee":"Owner"}]\\n'; fi ;;
  issues:bulk-get) printf '[{"id":"%s","uuid":"uuid-%s"}]\\n' "$3" "$3" ;;
  issues:update)
    if [[ "${4:-}" == --description ]]; then
      jq -cn --arg id "$3" --arg description "$5" '{issue:{identifier:$id,description:$description}}' > "$FIXTURE/repair"
    fi
    printf '{}\\n' ;;
  graphql:--query)
    case "$3" in
      'query OwnerTrackerComment('*)
        printf '%s\\n' '{"comment":{"bodyData":"{\\"type\\":\\"doc\\",\\"content\\":[{\\"type\\":\\"suggestion_userMentions\\",\\"attrs\\":{\\"id\\":\\"owner\\"}}]}"}}' ;;
      'query OwnerTracker('*) printf '{"issue":{"description":"Body","assignee":null,"labels":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}\\n' ;;
      'query OwnerItem('*)
        if [[ -e "$FIXTURE/readback" ]]; then cat "$FIXTURE/readback"
        else cat "$FIXTURE/repair"; fi ;;
      *) exit 1 ;;
    esac ;;
  comments:owner-questions)
    if [[ -e "$FIXTURE/question-id" ]]; then jq -cn --rawfile id "$FIXTURE/question-id" '$id | rtrimstr("\\n")'
    else printf '"question"\\n'; fi ;;
  comments:create)
    if [[ -e "$FIXTURE/question-id" ]]; then jq -cn --rawfile id "$FIXTURE/question-id" '{success:true,data:{comment:{id:($id | rtrimstr("\\n"))}}}'
    else printf '{"success":true,"data":{"comment":{"id":"question"}}}\\n'; fi ;;
  comments:react)
    if [[ -e "$FIXTURE/react-fails" ]]; then cat "$FIXTURE/react-fails" >&2; exit 1; fi
    printf '{"success":true,"data":{"reaction":{"emoji":"eyes"}}}\\n' ;;
  comments:bulk-list)
    [[ ! -e "$FIXTURE/unread-comments" ]] || exit 1
    cat "$FIXTURE/comments" ;;
  *) exit 1 ;;
esac
''')
    tracker.chmod(0o755)
    message = root / 'message'
    message.write_text('Approve this change?\n')
    call('ask', '--item', 'overseer', '--to', 'owner', '--issue', 'KEN-7', '--do', 'Approve change',
         '--options', 'approve,hold', '--recommend', 'approve', '--effect', 'none', '--wait', '5', '--file', str(message),
         cwd=worktree / 'subdir')
    comments = [dict(id='question', body='Question', user_email='bot@example.test', created_at='2026-01-02T00:00:00Z')]
    # A single input table covers the author/time contract.
    for id, author, at in [('before', 'owner@example.test', '2026-01-01'),
                           ('other', 'other@example.test', '2026-01-03'),
                           ('answer', 'OWNER@example.test', '2026-01-03')]:
        comments.append(dict(id=id, body=id, user_email=author, created_at=at+'T00:00:00Z'))
    (root / 'comments').write_text(json.dumps({'KEN-7': comments}))
    pending = call('pending', '--item', 'overseer', '--to', 'owner')
    assert 'tracker_posted' in pending.stdout, pending
    # The ask producer and all readers meet at the common checkout unless
    # the caller explicitly selects a mailbox root.
    root_cases = [(worktree / 'subdir', ()), (root / 'subdir', ()),
                  (worktree, ()), (root, ()), (worktree, ('--root', str(root)))]
    for cwd, options in root_cases:
        result = call('owner-answers', '--item', 'overseer', *options, cwd=cwd)
        assert not result.stderr, result
        assert result.stdout.splitlines()[-1] == 'owner-answers: read=read', result
        rows = [json.loads(line) for line in call('inbox', '--item', 'overseer', '--peek', cwd=cwd).stdout.splitlines() if line.startswith("{")]
        assert [row['text'] for row in rows] == ['answer'], rows
    call('owner-answers', '--item', 'overseer')
    again = [json.loads(line) for line in call('inbox', '--item', 'overseer', '--peek').stdout.splitlines() if line.startswith("{")]
    assert again == rows, again
    calls = (root / 'calls').read_text().splitlines()
    assert sum(line.startswith('comments bulk-list ') for line in calls) == len(root_cases) + 1
    # The answer's first delivery marks it; every later pass delivers nothing new and marks nothing.
    assert [line for line in calls if line.startswith('comments react ')] == ['comments react answer --emoji eyes'], calls
    # The repaired line names the question its ask posted, the line the watch removes on the close.
    assert 'issues update KEN-7 --description **Owner, what you do:** Approve change `Owner question: question`' in calls, calls
    for name, malformed in [('non-string-id', [dict(id=42, description='Body', assignee='Owner')]),
                             ('non-string-description', [dict(id='KEN-7', uuid='uuid-KEN-7', description=42, assignee='Owner')]),
                             ('false-description', [dict(id='KEN-7', uuid='uuid-KEN-7', description=False, assignee='Owner')]),
                             ('blank-assignee', [dict(id='KEN-7', uuid='uuid-KEN-7', description='Body', assignee='')])]:
        (root / 'items').write_text(json.dumps(malformed))
        unread = call('owner-answers', '--item', 'overseer')
        assert unread.stdout.splitlines()[-1] == 'owner-answers: read=unread', (name, unread)
        assert unread.stderr == 'KEN-3624-unread cause=issues-format\n', unread
    (root / 'items').unlink()
    for name, description, cause in [('invalid-repair-readback', 42, 'tracker-list-invalid'),
                                      ('false-repair-readback', False, 'tracker-list-invalid'),
                                      ('unlanded-repair', 'Body', 'unlanded')]:
        (root / 'readback').write_text(json.dumps(dict(issue=dict(identifier='KEN-7', description=description))))
        result = call('owner-answers', '--item', 'overseer')
        receipts = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        assert receipts[0]['kind'] == 'line' and receipts[0]['cause'] == cause, (name, result)
        assert result.stdout.splitlines()[-1] == 'owner-answers: read=read', result
    (root / 'readback').unlink()
    for status, reset, epoch, limit in [('missing', 'unavailable', None, 'requests'),
                                        ('invalid', 'unavailable', None, 'unknown'),
                                        ('future', '2100-01-01T00:00:00Z', 4102444800, 'complexity'),
                                        ('elapsed', '2000-01-01T00:00:00Z', 946684800, 'endpoint')]:
        receipt = dict(code='RATELIMITED', requests_reset='2100-01-01T00:01:00Z',
                       quota=dict(status=status, reset=reset, reset_epoch=epoch, limit=limit))
        (root / 'quota').write_text(json.dumps(receipt) + '\n')
        refused = call('owner-answers', '--item', 'overseer')
        assert json.loads(refused.stderr) == receipt, refused
        assert refused.stdout == f'EVENT tracker-quota status={status} reset={reset} limit={limit}\n', refused
        assert [json.loads(line) for line in call('inbox', '--item', 'overseer', '--peek').stdout.splitlines() if line.startswith('{')] == rows
    (root / 'quota').unlink()
    (root / 'unread-comments').touch()
    unread = call('owner-answers', '--item', 'overseer')
    assert unread.stdout.splitlines()[-1] == 'owner-answers: read=unread', unread
    assert unread.stderr == 'KEN-3624-unread cause=comments\n', unread
    (root / 'unread-comments').unlink()
    for malformed in ['', 'null', '[]', '{"KEN-7":[{"id":"broken"}]}']:
        (root / 'comments').write_text(malformed)
        unread = call('owner-answers', '--item', 'overseer')
        assert unread.stdout.splitlines()[-1] == 'owner-answers: read=unread', unread
        assert unread.stderr == 'KEN-3624-unread cause=comments-format\n', unread
    # A failed reaction keeps the delivery and prints one keyed line, never the
    # tracker's stderr: a quota receipt there would read as a held pass.
    quota = json.dumps(dict(code='RATELIMITED', quota=dict(status='missing', reset='unavailable', reset_epoch=None, limit='requests')))
    texts = ['answer']
    for day, (cause, refusal) in enumerate([('quota', quota), ('reaction-failed', '{"error":"Entity not found: Comment"}')], 4):
        id = f'answer-{cause}'
        comments.append(dict(id=id, body=cause, user_email='owner@example.test', created_at=f'2026-01-0{day}T00:00:00Z'))
        (root / 'comments').write_text(json.dumps({'KEN-7': comments}))
        (root / 'react-fails').write_text(refusal + '\n')
        texts.append(cause)
        for attempt in range(2):
            before = len((root / 'calls').read_text().splitlines())
            result = call('owner-answers', '--item', 'overseer')
            reacts = [line for line in (root / 'calls').read_text().splitlines()[before:] if line.startswith('comments react ')]
            assert reacts == ([f'comments react {id} --emoji eyes'] if attempt == 0 else []), (cause, attempt, reacts)
            assert result.stderr == (f'owner-answers: unmarked issue=KEN-7 comment={id} cause={cause}\n' if attempt == 0 else ''), result
            assert result.stdout.splitlines()[-1] == 'owner-answers: read=read', result
            receipts = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
            assert [r['comment'] for r in receipts if r['kind'] == 'delivered'] == ([id] if attempt == 0 else []), result
            rows = [json.loads(line) for line in call('inbox', '--item', 'overseer', '--peek').stdout.splitlines() if line.startswith('{')]
            assert [row['text'] for row in rows] == texts, rows
    (root / 'react-fails').unlink()
    message.write_text('Approve the explicit-root change?\n')
    call('ask', '--item', 'overseer', '--root', str(worktree), '--to', 'owner', '--issue', 'KEN-7',
         '--do', 'Approve explicit-root change', '--options', 'approve,hold', '--recommend', 'approve',
         '--effect', 'none', '--wait', '5', '--file', str(message))
    comments = [comments[0], dict(id='explicit', body='explicit', user_email='owner@example.test', created_at='2026-01-04T00:00:00Z')]
    (root / 'comments').write_text(json.dumps({'KEN-7': comments}))
    call('owner-answers', '--item', 'overseer', '--root', str(worktree))
    explicit = [json.loads(line) for line in call('inbox', '--item', 'overseer', '--root', str(worktree), '--peek').stdout.splitlines() if line.startswith('{')]
    assert [row['text'] for row in explicit] == ['explicit'], explicit
    assert [json.loads(line) for line in call('inbox', '--item', 'overseer', '--peek').stdout.splitlines() if line.startswith('{')] == rows
    # An ask closed on an answer given elsewhere, before any pass, marks the
    # owner's comment then: no later pass reads a closed ask's comments. A
    # deadline close marks nothing, and a comment a pass delivered keeps the
    # one mark it has.
    answer = root / 'relayed'
    answer.write_text('ship\n')
    # A read that fails names the item it leaves unmarked, and the close stands.
    for issue, close, pass_first, switch, marked, stderr in [
            ('KEN-9', ['--text', str(answer)], False, None, True, ''),
            ('KEN-10', [], False, None, True, ''),
            ('KEN-11', ['--default'], False, None, False, ''),
            ('KEN-12', ['--text', str(answer)], True, None, False, ''),
            ('KEN-13', ['--text', str(answer)], False, ('react-fails', '{"error":"Entity not found: Comment"}\n'), True,
             'owner-answers: unmarked issue=KEN-13 comment=relay-KEN-13 cause=reaction-failed\n'),
            ('KEN-14', ['--text', str(answer)], False, ('unread-comments', ''), False,
             'owner-answers: unmarked issue=KEN-14 cause=comments-unread\n'),
            ('KEN-15', ['--text', str(answer)], False, ('quota', quota + '\n'), False,
             'owner-answers: unmarked issue=KEN-15 cause=quota\n')]:
        (root / 'question-id').write_text(f'question-{issue}\n')
        message.write_text(f'Ship {issue}?\n')
        asked = call('ask', '--item', 'overseer', '--to', 'owner', '--issue', issue, '--do', 'Ship change',
                     '--options', 'ship,hold', '--recommend', 'ship', '--effect', 'none', '--wait', '5', '--file', str(message))
        ask = asked.stdout.strip().split('=', 1)[1]
        comment = f'relay-{issue}'
        (root / 'comments').write_text(json.dumps({issue: [
            dict(id=f'question-{issue}', body='Question', user_email='bot@example.test', created_at='2026-01-05T00:00:00Z'),
            dict(id=comment, body='ship', user_email='owner@example.test', created_at='2026-01-06T00:00:00.123Z'),
            # Written after the close, threaded or not: no route took either to the ask.
            dict(id=f'late-{issue}', body='later', user_email='owner@example.test', created_at='2100-01-01T00:00:00.500Z'),
            dict(id=f'late-reply-{issue}', body='later', user_email='owner@example.test',
                 parent_id=f'question-{issue}', created_at='2100-01-01T00:00:01.500Z')]}))
        if pass_first:
            call('owner-answers', '--item', 'overseer')
        if switch:
            (root / switch[0]).write_text(switch[1])
        before = len((root / 'calls').read_text().splitlines())
        (root / 'closes-at-read').unlink(missing_ok=True)
        closed = call('resolve', '--item', 'overseer', '--id', ask, *close)
        # No tracker call holds the local close: the comments are read after it lands.
        closes = sum(json.loads(line)['kind'] == 'resolution'
                     for line in (root / 'tmp/lane-mail/overseer/to-lane.jsonl').read_text().splitlines())
        read_at = (root / 'closes-at-read').read_text().strip() if (root / 'closes-at-read').exists() else None
        assert read_at == (None if close == ['--default'] else str(closes)), (issue, read_at, closes)
        if switch:
            (root / switch[0]).unlink()
        assert closed.stderr == stderr, (issue, closed)
        assert closed.stdout.startswith(f'lane-mail: resolved id={ask} '), (issue, closed)
        later = call('owner-answers', '--item', 'overseer')
        assert later.stdout.splitlines()[-1] == 'owner-answers: read=read', (issue, later)
        reacts = [line for line in (root / 'calls').read_text().splitlines()[before:] if line.startswith('comments react ')]
        assert reacts == ([f'comments react {comment} --emoji eyes'] if marked else []), (issue, reacts)
    # An ask on a GitHub-synced item posts with no action line, and no pass
    # writes one there: the item refuses every description write.
    (root / 'synced-KEN-16').touch()
    (root / 'question-id').write_text('question-KEN-16\n')
    message.write_text('Ship KEN-16?\n')
    asked = call('ask', '--item', 'overseer', '--to', 'owner', '--issue', 'KEN-16', '--do', 'Ship change',
                 '--options', 'ship,hold', '--recommend', 'ship', '--effect', 'none', '--wait', '5', '--file', str(message))
    ask = asked.stdout.strip().split('=', 1)[1]
    synced = [row for row in (json.loads(line) for line in call('pending', '--item', 'overseer', '--to', 'owner').stdout.splitlines()
                              if line.startswith('{')) if row['id'] == ask]
    assert [(row['tracker_posted'], row.get('tracker_action_line')) for row in synced] == [(True, False)], (asked, synced)
    (root / 'items').write_text(json.dumps([dict(id=issue, uuid=f'uuid-{issue}', description='Body', assignee='Owner')
                                            for issue in ('KEN-7', 'KEN-16')]))
    (root / 'comments').write_text(json.dumps({'KEN-7': [comments[0]], 'KEN-16': [
        dict(id='question-KEN-16', body='Question', user_email='bot@example.test', created_at='2026-01-07T00:00:00Z')]}))
    before = len((root / 'calls').read_text().splitlines())
    result = call('owner-answers', '--item', 'overseer')
    writes = [line for line in (root / 'calls').read_text().splitlines()[before:] if line.startswith('issues update KEN-16 ')]
    receipts = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    assert writes == [] and [r for r in receipts if r['kind'] == 'line' and r['issue'] == 'KEN-16'] == [], (writes, result)
    assert result.stdout.splitlines()[-1] == 'owner-answers: read=read', result
    print('PASS owner answer delivery, filtering, deduplication, repair, absent tracker and quota refusal')
PY
pass 'owner answer delivery, filtering, repair and quota contract'
TMP_ROOT="$(mktemp -d "$ROOT/tmp/owner-answers.XXXXXX")" || { echo 'owner-answers: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'owner-answers: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'owner-answers: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# Which open ask each owner comment reaches, each row judged on its own tracker.
mkdir "$TMP_ROOT/replace"
REPLACE_FACTS="$(python3 "$ROOT/skills/mailbox/tests/lib/owner-replace.py" answers \
  "${MAILBOX_UNDER_TEST:-$ROOT/skills/mailbox}" "$TMP_ROOT/replace" "$BASH")"
assert_eq "$(jq -c 'with_entries(select(.key | startswith("error:")))' <<<"$REPLACE_FACTS")" '{}' \
  'every answer case runs to its observation'
while IFS='|' read -r fact contract; do
  [[ -n "$fact" ]] || continue
  assert_eq "$(jq --arg fact "$fact" '.[$fact]' <<<"$REPLACE_FACTS")" true "$contract"
done <<'ROWS'
replaced_reply|a reply under a replaced question reaches the open replacement, opening with the line naming both asks
chat_replaced|a reply under a question a chat ask replaced reaches that chat ask, after the watch cleared the item
chain_first_replaced|a reply under the first question of a three-ask chain, on another item, reaches the one open ask
thread_chain|a reply under another mailbox's question is not delivered, while a nested reply whose thread ends at this mailbox's question is
flat_comment|a top-level comment after the open question reaches its ask, after a re-ask the newest one's, and one with no open question before it is left out
missing_item|an item Linear holds no issue for is named on stderr and the other items are read
uuid_ref|an ask made by a UUID is read off the owner list by its recorded identifier, and one known by a UUID alone is named on stderr while the other items are read
close_replaced|a reply posted before its question was replaced takes no mark from the replacement's close, and one mark when owner-answers delivers it to the replacing ask
close_chat|a chat ask that replaced an item question marks the reply under that question once when it closes on an answer given elsewhere
close_missing|a close whose replaced question is on a missing item names that item and marks the reply on the live item
ROWS
if [[ -z "${MAILBOX_UNDER_TEST:-}" ]]; then
  cp -R "$ROOT/skills/mailbox/scripts" "$TMP_ROOT/scripts"
  python3 - "$TMP_ROOT/scripts/lane-mail" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
old = '.at < $row.created_at'
assert source.count(old) == 1
path.write_text(source.replace(old, '.at > $row.created_at'))
PY
  rc=0
  MAILBOX_UNDER_TEST="$TMP_ROOT" "$BASH" "$ROOT/skills/mailbox/tests/owner-answers.sh" >"$TMP_ROOT/control.log" 2>&1 || rc=$?
  assert_eq "$rc" 1 'inverted time selection fails the fixture'
  assert_file_contains "$TMP_ROOT/control.log" "'text': 'before'" 'the control reaches the delivered-comment assertion'
  cp "$ROOT/skills/mailbox/scripts/lane-mail" "$TMP_ROOT/scripts/lane-mail"
  python3 - "$TMP_ROOT/scripts/lane-mail" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
old = '  TRACKER="$SCRIPT_DIR/../../linear/scripts/linear.sh"'
assert source.count(old) == 1
path.write_text(source.replace(old, old + '\n  ROOT="${ROOT:-$PWD}"'))
PY
  rc=0
  MAILBOX_UNDER_TEST="$TMP_ROOT" "$BASH" "$ROOT/skills/mailbox/tests/owner-answers.sh" >"$TMP_ROOT/root-control.log" 2>&1 || rc=$?
  assert_eq "$rc" 1 'caller-directory root selection fails the fixture'
  assert_file_contains "$TMP_ROOT/root-control.log" 'AssertionError: []' 'the root control reaches the missing-answer assertion'
  cp "$ROOT/skills/mailbox/scripts/lane-mail" "$TMP_ROOT/scripts/lane-mail"
  python3 - "$TMP_ROOT/scripts/lane-mail" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
old = '  cat -- "$1" >&2'
assert source.count(old) == 1
path.write_text(source.replace(old, '  : # ' + old.strip()))
PY
  rc=0
  MAILBOX_UNDER_TEST="$TMP_ROOT" "$BASH" "$ROOT/skills/mailbox/tests/owner-answers.sh" >"$TMP_ROOT/quota-control.log" 2>&1 || rc=$?
  assert_eq "$rc" 1 'a dropped quota receipt fails the fixture'
  assert_file_contains "$TMP_ROOT/quota-control.log" 'JSONDecodeError' 'the quota control reaches the reset receipt assertion'
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
