#!/usr/bin/env bash
# LaneMail answer failures, event field validation and root-error isolation.
# Controls keep the malformed producer and remove each reader rule.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start --page 2
echo "=== slack mailbox events ==="

# A failed jq closure scan must stop a real owner answer, not turn it into
# a directive. The wrapper leaves the ask read and all envelope writes real.
SCAN="$(sk_new_root closure-scan)"
sk_bind "$SCAN"
sk_lm "$SCAN" ask --item overseer --to owner --file "$(sk_text scan 'Scan?')" --options a,b --recommend a >/dev/null
sk_poll "$SCAN"
SCAN_CH="$(sk_channel "$SCAN")"
SCAN_TS="$(sk_state ".messages.${SCAN_CH}[-1].ts")"
mkdir -p "$SCAN/tmp/fault-bin"
REAL_JQ="$(command -v jq)" || exit 1
python3 - "$SCAN" "$REAL_JQ" "$SK_LANE_MAIL" <<'PY'
import pathlib, shlex, sys
root, jq, mail = pathlib.Path(sys.argv[1]), shlex.quote(sys.argv[2]), shlex.quote(sys.argv[3])
fault = root / "tmp/fault-bin/jq"
fault.write_text('#!/usr/bin/env bash\nset -euo pipefail\nfor arg in "$@"; do\ncase "$arg" in\n*\'select(overseer_mail_class == "close"\'*) printf "jq-fault=closure\\n" >&2; exit 5 ;;\nesac\ndone\nexec ' + jq + ' "$@"\n')
fault.chmod(0o755)
scripts = root / ".agents/skills/orch/scripts"
scripts.unlink()
scripts.mkdir()
entry = scripts / "lane-mail"
entry.write_text('#!/usr/bin/env bash\nset -euo pipefail\nexec env PATH=' + shlex.quote(str(fault.parent)) + ':"$PATH" ' + mail + ' "$@"\n')
entry.chmod(0o755)
PY
SCAN_REPLY="$(sk_inject "$SCAN_CH" U001 b "$SCAN_TS")"
sk_poll "$SCAN"
assert_eq "$RC=$ERR1" "1=slack: lane-mail-failed=lane-mail: mail-read-failed=overseer" "a failed closure scan stops owner delivery"
assert_has "$ERR" "jq-fault=closure" "the relay retains the closure scan diagnostic"
assert_eq "$(jq -s --arg key "$SCAN_CH:$SCAN_REPLY" '[.[] | select(.delivery_id == $key)] | length' "$(sk_box "$SCAN")/to-lane.jsonl")" "0" "a scan failure delivers neither an answer nor a directive"
sk_mutant answer-diagnostic mailbox.py '(return "resolved-already", first.rsplit\("id=", 1\)\[1\].strip\(\)\n        )raise Refusal\("lane-mail-failed", err.strip\(\) or first\)' '\1raise Refusal("lane-mail-failed", first)'
sk_poll "$SCAN"
CONTROL_FAIL="$SK_FAIL"
CONTROL_RC=0
CONTROL_OUT="$(
  assert_has "$ERR" "jq-fault=closure" "the relay retains the closure scan diagnostic"
  [ "$SK_FAIL" = "$CONTROL_FAIL" ]
)" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" "1" "control: truncating the guard failure loses its dependency diagnostic"
sk_bin_reset

# --- older event producers and malformed envelope fields ----------------------
# lane-mail's older events output lacks positions. Corrupt mailbox objects
# can also reach the relay because lane-mail filters JSON syntax, not fields.
while IFS='|' read -r name field expression posted; do
  R="$(sk_new_root "field-$name")"
  sk_bind "$R"
  sk_poll "$R"
  sk_lm "$R" notice --item overseer --to owner --file "$(sk_text "$name-bad" 'Malformed field.')" >/dev/null
  BAD_ID="$(tail -n 1 "$(sk_box "$R")/to-overseer.jsonl" | jq -r .id)"
  sk_lm "$R" notice --item overseer --to owner --file "$(sk_text "$name-good" 'Healthy envelope.')" >/dev/null
  sk_event_filter "$R" "if .text == \"Malformed field.\" then $expression else . end"
  if [ "$field" = line ] || [ "$field" = count ]; then
    sk_master_read "$R" 1
    printf '{"t":"hold","at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$(sk_journal "$R")"
  fi
  sk_poll "$R"
  CH="$(sk_channel "$R")"
  [ "$field" != id ] || BAD_ID=unknown
  assert_eq "$RC=$(asks "$CH" 'Malformed field.')=$(asks "$CH" 'Healthy envelope.')=$ERR" \
    "0=$posted=1=slack: envelope-field=$R id=$BAD_ID field=$field" "$name: only the invalid envelope field degrades or skips; the next envelope posts"
done <<'ROWS'
missing-line|line|del(.line)|1
bad-line|line|.line = "one"|1
missing-count|count|del(.count)|1
bad-count|count|.count = []|1
missing-id|id|del(.id)|0
missing-at|at|del(.at)|0
bad-at|at|.at = "not-a-date"|0
missing-text|text|del(.text)|0
bad-text|text|.text = 17|0
bad-kind|kind|.kind = []|0
bad-box|box|.box = {}|0
unknown-kind|kind|.kind = "unknown"|0
unknown-box|box|.box = "unknown"|0
bad-options|options|.options = [17]|0
bad-deadline|deadline|.deadline = "not-a-date"|0
ROWS

LEGACY="$(sk_new_root legacy-events)"
HEALTHY="$(sk_new_root healthy-events)"
for R in "$LEGACY" "$HEALTHY"; do
  sk_bind "$R"
  sk_poll "$R"
  sk_lm "$R" notice --item overseer --to owner --file "$(sk_text "$(basename "$R")" 'Multi-root notice.')" >/dev/null
done
sk_event_filter "$LEGACY" 'del(.line, .count)'
sk_run -- listen --once --root "$LEGACY" --root "$HEALTHY"
assert_eq "$RC=$(asks "$(sk_channel "$LEGACY")" 'Multi-root notice.')=$(asks "$(sk_channel "$HEALTHY")" 'Multi-root notice.')" \
  "0=1=1" "a legacy root without line or count and a healthy root both post"
LEGACY_ID="$(jq -r .id "$(sk_box "$LEGACY")/to-overseer.jsonl")" || exit 1
printf -v LEGACY_WARNINGS 'slack: envelope-field=%s id=%s field=line\nslack: envelope-field=%s id=%s field=count' \
  "$LEGACY" "$LEGACY_ID" "$LEGACY" "$LEGACY_ID"
HELP_RC=0
sk_help_field || HELP_RC=$?
assert_eq "$HELP_RC" "0" "help advertises the envelope-field diagnostic reached by legacy events"
RC=0
WARNINGS="$(sk_legacy_warnings "$LEGACY" "$LEGACY_WARNINGS")" || RC=$?
assert_eq "$RC=$WARNINGS" "0=$LEGACY_WARNINGS" "reading legacy events twice through one LaneMail warns once per root, id and field"

# Keep HELP and the runtime diagnostic intact; conceal only its help output.
sk_mutant help-field main.py 'sys\.stdout\.write\(HELP\)' 'sys.stdout.write(HELP.replace("envelope-field=ROOT id=ID field=FIELD", ""))'
HELP_RC=0
sk_help_field || HELP_RC=$?
assert_eq "$HELP_RC" "1" "control: concealing the help key fails the help assertion while diagnostics remain"
RC=0
WARNINGS="$(sk_legacy_warnings "$LEGACY" "$LEGACY_WARNINGS")" || RC=$?
assert_eq "$RC=$WARNINGS" "0=$LEGACY_WARNINGS" "control: the hidden help key leaves legacy envelope diagnostics unchanged"
sk_bin_reset

# A corrupt UTF-8 subprocess response is a root read error, not an envelope
# field. The healthy root must post even when the first root cannot decode it.
BROKEN="$(sk_new_root broken-events)"
sk_bind "$BROKEN"
sk_poll "$BROKEN"
rm -- "$BROKEN/.agents/skills/orch/scripts"
mkdir -p "$BROKEN/.agents/skills/orch/scripts"
printf '#!/usr/bin/env bash\nprintf "\\377\\n"\n' > "$BROKEN/.agents/skills/orch/scripts/lane-mail"
chmod +x "$BROKEN/.agents/skills/orch/scripts/lane-mail"
rm -- "$BROKEN/tmp/slack/status.json"
mkdir "$BROKEN/tmp/slack/status.json"
sk_lm "$HEALTHY" notice --item overseer --to owner --file "$(sk_text root-error 'Healthy after root error.')" >/dev/null
sk_run -- listen --once --root "$BROKEN" --root "$HEALTHY"
assert_eq "$RC=$(asks "$(sk_channel "$HEALTHY")" 'Healthy after root error.')=$(printf '%s\n' "$ERR" | grep -c '^slack: root-poll-failed=')" \
  "1=1=1" "a root read error reports once and does not stop healthy-root routing"
assert_has "$ERR1" "slack: root-poll-failed=$BROKEN cause=UnicodeDecodeError:" "the root error names the root and actual cause"

sk_mutant repeated-fields mailbox.py 'if pair not in self\.reported_fields:' 'if True:'
RC=0
WARNINGS="$(sk_legacy_warnings "$LEGACY" "$LEGACY_WARNINGS")" || RC=$?
assert_eq "$RC=$WARNINGS" "1=$LEGACY_WARNINGS"$'\n'"$LEGACY_WARNINGS" \
  "control: bypassing the repeat check keeps diagnostics and fails the once-per-field assertion"
sk_bin_reset

sk_mutant missing-line relay.py 'envelope\["line"\] is not None and ' ''
sk_lm "$LEGACY" notice --item overseer --to owner --file "$(sk_text line-control 'Line control.')" >/dev/null
sk_poll "$LEGACY"
assert_eq "$RC=$(asks "$(sk_channel "$LEGACY")" 'Line control.')" "1=0" "control: requiring line again fails the legacy notice poll"
sk_bin_reset

sk_mutant invalid-field mailbox.py 'if invalid:' 'if False:'
sk_poll "$SK_TMP/field-bad-at"
assert_eq "$RC" "1" "control: routing a malformed field again fails the envelope poll"
sk_bin_reset

sk_mutant field-type mailbox.py 'if not isinstance\(value, str\) or \(field != "text" and required and not value\):' 'if False:'
sk_poll "$SK_TMP/field-bad-text"
assert_eq "$RC" "1" "control: accepting a malformed text type again fails the poll"
sk_bin_reset

sk_mutant field-date mailbox.py 'except ValueError:\n                            self.bad_field\(envelope.get\("id"\), field\)\n                            invalid = True' 'except ValueError:\n                            self.bad_field(envelope.get("id"), field)\n                            invalid = False'
sk_poll "$SK_TMP/field-bad-at"
assert_eq "$RC" "1" "control: accepting a malformed timestamp again fails the poll"
sk_bin_reset

sk_mutant field-options mailbox.py 'if not isinstance\(options, list\) or not all\(isinstance\(option, str\) for option in options\):' 'if False:'
sk_poll "$SK_TMP/field-bad-options"
assert_eq "$(asks "$(sk_channel "$SK_TMP/field-bad-options")" 'Malformed field.')" "1" "control: accepting malformed options posts the invalid envelope"
sk_bin_reset

sk_mutant missing-count relay.py 'if None in counts:' 'if False:'
sk_master_read "$SK_TMP/field-missing-count" 1
printf '{"t":"hold","at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$(sk_journal "$SK_TMP/field-missing-count")"
sk_poll "$SK_TMP/field-missing-count"
assert_eq "$RC" "1" "control: requiring count again fails a legacy resume poll"
sk_bin_reset

sk_mutant field-choice mailbox.py 'FIELD_CHOICES = .*' 'FIELD_CHOICES = {}'
sk_poll "$SK_TMP/field-unknown-kind"
assert_eq "$ERR" "" "control: unknown field choices no longer get a keyed diagnostic"
sk_bin_reset

sk_mutant root-isolation relay.py 'except Exception as err:' 'except Refusal as err:'
sk_lm "$HEALTHY" notice --item overseer --to owner --file "$(sk_text root-control 'Root control.')" >/dev/null
sk_run -- listen --once --root "$BROKEN" --root "$HEALTHY"
assert_eq "$RC=$(asks "$(sk_channel "$HEALTHY")" 'Root control.')" "1=0" "control: the root error escapes and prevents the healthy root from posting"
sk_bin_reset

sk_mutant status-isolation relay.py 'except Exception as status_err:' 'except Refusal as status_err:'
sk_run -- listen --once --root "$BROKEN" --root "$HEALTHY"
assert_eq "$RC=$(asks "$(sk_channel "$HEALTHY")" 'Root control.')" "1=0" "control: a failed error-status write prevents the healthy root from posting"
sk_bin_reset

sk_summary
