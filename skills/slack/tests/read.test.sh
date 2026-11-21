#!/usr/bin/env bash
# Surface: read. Inputs: slack/scripts/ and tests/lib/.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start --page 2
CH=C_READ
sk_inject "$CH" U001 'Older than the requested window.' >/dev/null
TOP="$(sk_inject "$CH" U001 'First line
Second line')"
REPLY="$(sk_inject "$CH" U002 'Thread reply.' "$TOP")"
BOT="$(sk_inject "$CH" UBOT 'Heartbeat: ready.' '' '"bot_id":"B001", "edited":{"ts":"2000000000.000001"}')"
LAST="$(sk_inject "$CH" U002 $'Last \\ literal text=tail.\rEnd')"
sk_inject "$CH" U002 'Broadcast reply.' "$TOP" '"subtype":"thread_broadcast"' >/dev/null
EXPECTED="slack: ts=$TOP edited=- user=U001 text=First line\nSecond line
slack: ts=$BOT edited=2000000000.000001 bot=B001 text=Heartbeat: ready.
slack: ts=$LAST edited=- user=U002 text=Last \\\\ literal text=tail.\rEnd"

# This caller has no checkout or binding. A binding read must also fail if
# it tries the malformed file in the launch directory.
mkdir -p "$SK_TMP/home/tmp/slack"
printf 'not-json\n' > "$SK_TMP/home/tmp/slack/binding.json"
sk_run SLACK_OWNERS= -- read --channel "$CH" --latest 3
assert_eq "$RC=$OUT" "0=$EXPECTED" 'binding-free latest read prints author, edit time and escaped text across pages'
assert_eq "$ERR" '' 'binding-free read needs no owner setting'

sk_run -- read --channel "$CH" --ts "$TOP"
assert_eq "$RC=$OUT" "0=slack: ts=$TOP edited=- user=U001 text=First line\nSecond line
slack: ts=$REPLY edited=- user=U002 text=Thread reply.
slack: ts=$(sk_state ".messages.${CH}[] | select(.subtype == \"thread_broadcast\") | .ts") edited=- user=U002 text=Broadcast reply." 'thread read prints the parent and every reply oldest first'
sk_run -- read --channel C_EMPTY --latest 3
assert_eq "$RC=$OUT" '0=' 'empty channel succeeds with no output'
sk_run -- read --channel "$CH" --latest 20
assert_has "$OUT" 'text=Older than the requested window.' 'a short channel returns its available top-level messages'
EMPTY_AUTHOR="$(sk_inject "$CH" '' '')"
sk_run -- read --channel "$CH" --latest 1
assert_eq "$RC=$OUT" "0=slack: ts=$EMPTY_AUTHOR edited=- user=- text=" 'a message without an author or text keeps the line fields'

for method in conversations.history conversations.replies; do
  sk_ctl /_test/fault "{\"method\":\"$method\",\"error\":\"channel_not_found\"}" >/dev/null
  if [ "$method" = conversations.history ]; then
    sk_run -- read --channel "$CH" --latest 3
  else
    sk_run -- read --channel "$CH" --ts "$TOP"
  fi
  assert_eq "$RC=$ERR1" "2=slack: slack-api-failed=$method error=channel_not_found" "$method refusal keeps its keyed failure"
  assert_eq "$OUT" '' 'a refused read prints no messages'
done

for value in 0 -1 wrong; do
  sk_run -- read --channel "$CH" --latest "$value"
  assert_eq "$RC=${ERR1%%=*}" '2=slack: usage' "invalid latest count $value is refused"
done
for args in '--latest 3' '--channel C_READ' '--channel C_READ --latest 3 --ts T'; do
  # Each row deliberately supplies separate CLI words.
  # shellcheck disable=SC2086
  sk_run -- read $args
  assert_eq "$RC=${ERR1%%=*}" '2=slack: usage' "incomplete or conflicting selector $args is refused"
done

# What a redirect target of a Web API call receives as Authorization, with
# SK_BIN's client: an origin answers 302 to a second server on another port.
redirect_auth() {
  python3 - "${SK_BIN%/*}/lib" <<'PY'
import http.server, json, sys, threading
sys.path.insert(0, sys.argv[1])
from api import Slack
seen = []
class Target(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        seen.append(self.headers.get("Authorization"))
        body = b'{"ok": true}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
target = http.server.HTTPServer(("127.0.0.1", 0), Target)
class Origin(Target):
    def do_GET(self):
        self.send_response(302)
        self.send_header("Location", "http://127.0.0.1:%d/landed" % target.server_port)
        self.send_header("Content-Length", "0")
        self.end_headers()
origin = http.server.HTTPServer(("127.0.0.1", 0), Origin)
for server in (target, origin):
    threading.Thread(target=server.serve_forever, daemon=True).start()
Slack("redirect-token", "http://127.0.0.1:%d/api" % origin.server_port).get("auth.test", retries=0)
print(json.dumps(seen))
PY
}
assert_eq "$(redirect_auth)" '[null]' 'a Web API redirect target receives no token'

sk_mutant positive-latest main.py 'if args.latest is not None and args.latest < 1:' 'if args.latest is not None and False:'
sk_run -- read --channel "$CH" --latest 0
assert_eq "$RC=$OUT" '0=' 'control: removing the positive-count rule accepts an empty read'
sk_bin_reset
sk_mutant redirect-auth api.py 'req\.add_unredirected_header\("Authorization", f"Bearer \{self\.token\}"\)\n        return self\._request\(req, method, retries\)' 'req.add_header("Authorization", f"Bearer {self.token}")\n        return self._request(req, method, retries)'
assert_eq "$(redirect_auth)" '["Bearer redirect-token"]' 'control: an added header follows the redirect with the token'
sk_bin_reset
sk_summary
