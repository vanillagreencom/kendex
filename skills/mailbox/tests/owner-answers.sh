#!/usr/bin/env bash
# Surface: one-pass owner answer delivery.
# Inputs: skills/mailbox/scripts/**, skills/orch/tests/lib/assertions.sh.
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
if [[ -e "$FIXTURE/quota" ]]; then
  cat "$FIXTURE/quota" >&2
  exit 1
fi
case "$1:$2" in
  users:list) printf '[{"id":"owner","name":"Owner","email":"owner@example.test","display_name":"owner"}]\\n' ;;
  teams:keys) printf '{"urlKey":"workspace","keys":["KEN"]}\\n' ;;
  issues:list)
    if [[ -e "$FIXTURE/items" ]]; then cat "$FIXTURE/items"
    else printf '[{"id":"KEN-7","description":"Body","assignee":"Owner"}]\\n'; fi ;;
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
  comments:create) printf '{"success":true,"data":{"comment":{"id":"question"}}}\\n' ;;
  comments:bulk-list)
    [[ ! -e "$FIXTURE/unread-comments" ]] || exit 1
    cat "$FIXTURE/comments" ;;
  *) exit 1 ;;
esac
''')
    tracker.chmod(0o755)
    # A report of an unmatched owner comment is a data notice, which needs a
    # registered overseer: agent-runtime's controller status says one is.
    runtime = root / '.agents/skills/agent-runtime/scripts/agent-runtime'
    runtime.parent.mkdir(parents=True)
    runtime.write_text('#!/bin/sh\nprintf \'%s\\n\' \'{"ok":true,"result":{"recorded":{},"live":true}}\'\n')
    runtime.chmod(0o755)
    message = root / 'message'
    message.write_text('Approve this change?\n')
    call('ask', '--item', 'overseer', '--to', 'owner', '--issue', 'KEN-7', '--do', 'Approve change',
         '--options', 'approve,hold', '--recommend', 'approve', '--effect', 'none', '--wait', '5', '--file', str(message),
         cwd=worktree / 'subdir')
    comments = [dict(id='question', body='Question', user_email='bot@example.test', created_at='2026-01-02T00:00:00Z')]
    # A single input table covers the author/time contract: the owner's
    # comment after the question answers it, and one from before the item's
    # oldest question is neither delivered nor reported.
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
        assert [(row['kind'], row.get('delivery_id')) for row in rows] == [('answer', 'linear:answer')], rows
        assert rows[0]['text'] == 'answer', rows
    call('owner-answers', '--item', 'overseer')
    again = [json.loads(line) for line in call('inbox', '--item', 'overseer', '--peek').stdout.splitlines() if line.startswith("{")]
    assert again == rows, again
    calls = (root / 'calls').read_text().splitlines()
    assert sum(line.startswith('comments bulk-list ') for line in calls) == len(root_cases) + 1
    assert any(line.startswith('issues update KEN-7 --description **Owner, what you do:** Approve change') for line in calls)
    for name, malformed in [('non-string-id', [dict(id=42, description='Body', assignee='Owner')]),
                             ('non-string-description', [dict(id='KEN-7', description=42, assignee='Owner')]),
                             ('false-description', [dict(id='KEN-7', description=False, assignee='Owner')]),
                             ('blank-assignee', [dict(id='KEN-7', description='Body', assignee='')])]:
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
    comments.append(dict(id='later-answer', body='later', user_email='owner@example.test', created_at='2026-01-04T00:00:00Z'))
    (root / 'comments').write_text(json.dumps({'KEN-7': comments}))
    for _ in range(2):
        call('owner-answers', '--item', 'overseer')
        rows = [json.loads(line) for line in call('inbox', '--item', 'overseer', '--peek').stdout.splitlines() if line.startswith('{')]
        assert [(row['kind'], row.get('delivery_id')) for row in rows] == [
            ('answer', 'linear:answer'), ('answer', 'linear:later-answer')], rows
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
    print('PASS owner answer delivery, filtering, deduplication, repair, absent tracker and quota refusal')
PY
pass 'owner answer delivery, filtering, repair and quota contract'
if [[ -z "${MAILBOX_UNDER_TEST:-}" ]]; then
  TMP_ROOT="$(mktemp -d "$ROOT/tmp/owner-answers.XXXXXX")" || { echo 'owner-answers: scratch=mktemp-failed' >&2; exit 1; }
  [[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'owner-answers: scratch=not-a-directory' >&2; exit 1; }
  TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'owner-answers: scratch=resolve-failed' >&2; exit 1; }
  trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
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
  assert_file_contains "$TMP_ROOT/control.log" "'kind': 'data'" 'the control reaches the delivered-comment assertion'
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
