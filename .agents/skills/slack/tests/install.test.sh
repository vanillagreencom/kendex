#!/usr/bin/env bash
# `slack install`: the unit printed with --print and written under the
# systemd user directory otherwise, its ExecStart naming every root, the
# daemon-reload, enable and restart that follow and the state read after
# them, a reinstall over a running unit restarting it on the new roots, the
# refusals for a missing or failing systemctl, a unit that did not stay
# active, an unbound root and no root, and `setup` restarting the unit that
# stands. Two controls, one per rule: a mutant whose ExecStart names no root,
# and one whose setup no longer restarts the unit.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack install ==="

ROOT="$(sk_new_root alpha)"
BETA="$(sk_new_root beta)"
sk_bind "$ROOT"
sk_bind "$BETA"
CFG="$SK_TMP/cfg"
UNIT="$CFG/systemd/user/slack-listen.service"
LOG="$SK_TMP/systemctl.log"
BIN="$(sk_fake_systemctl)"

# --- --print writes the unit to stdout and nothing to disk ------------------------
sk_run XDG_CONFIG_HOME="$CFG" -- install --root "$ROOT" --root "$BETA" --print
assert_eq "$RC" 0 "--print exits 0"
assert_has "$OUT" "ExecStart=$SK_SLACK listen --root $ROOT --root $BETA" "the unit's ExecStart runs listen over every root, in order"
assert_has "$OUT" "WorkingDirectory=$ROOT" "the unit's working directory is the first root"
assert_lacks "$OUT" "@" "every placeholder of the template is filled"
assert_eq "$([ -e "$UNIT" ] && echo present || echo absent)" "absent" "--print writes no unit file"

# --- install writes the unit, then reloads and enables it -----------------------------
sk_run XDG_CONFIG_HOME="$CFG" PATH="$BIN:$PATH" -- install --root "$ROOT"
assert_eq "$RC=$OUT" "0=slack: installed=$UNIT
slack: enabled=slack-listen.service
slack: active=slack-listen.service" "install prints the unit path, the enabled unit and its active state"
assert_eq "$(sed -n 's/^ExecStart=//p' "$UNIT")" "$SK_SLACK listen --root $ROOT" "the written unit runs listen over the root"
assert_eq "$(cat "$LOG")" "--user daemon-reload
--user enable slack-listen.service
--user restart slack-listen.service
--user is-active slack-listen.service" "install reloads the user manager, enables and restarts the unit, then reads its state"
: > "$LOG"
sk_run XDG_CONFIG_HOME="$CFG" PATH="$BIN:$PATH" -- install --root "$ROOT" --root "$BETA"
assert_eq "$RC=$(sed -n 's/^ExecStart=//p' "$UNIT")=$(grep -c '^--user restart slack-listen.service$' "$LOG")" \
  "0=$SK_SLACK listen --root $ROOT --root $BETA=1" "a reinstall adding a root over the active unit restarts it on the new ExecStart"
sk_run XDG_CONFIG_HOME="$CFG" PATH="$BIN:$PATH" FAKE_SYSTEMCTL_ACTIVE=activating -- install --root "$ROOT"
assert_eq "$RC=$ERR1" "2=slack: unit-inactive=slack-listen.service state=activating fix=journalctl --user -u slack-listen.service" \
  "a unit not active after the start wait is refused with the log to read"

# --- setup restarts the unit that stands, and only then ----------------------------------
: > "$LOG"
sk_run XDG_CONFIG_HOME="$CFG" PATH="$BIN:$PATH" -- setup --root "$ROOT"
assert_eq "$RC=$(printf '%s' "$OUT" | sed -n '2p')" "0=slack: restarted=slack-listen.service" "setup prints the unit it restarted"
assert_eq "$(cat "$LOG")" "--user try-restart slack-listen.service" "setup restarts the installed unit"
: > "$LOG"
sk_run XDG_CONFIG_HOME="$SK_TMP/cfg-none" PATH="$BIN:$PATH" -- setup --root "$ROOT"
assert_eq "$RC=$(cat "$LOG")" "0=" "with no unit installed, setup runs no systemctl"
sk_run XDG_CONFIG_HOME="$CFG" PATH="$BIN:$PATH" FAKE_SYSTEMCTL_EXIT=1 -- setup --root "$ROOT"
assert_eq "$RC=$ERR1" "2=slack: systemctl-failed=systemctl --user try-restart slack-listen.service exit=1" \
  "a restart systemctl refuses is refused with its exit status"
assert_eq "$(printf '%s' "$OUT" | sed -n '1p' | cut -d= -f1)=$(printf '%s' "$OUT" | grep -c 'restarted=')" "slack: bound=0" \
  "the binding stands and no restart is claimed"

# --- refusals, one row per rule ------------------------------------------------------------
NOSYS="$(sk_path_without systemctl)"
sk_run XDG_CONFIG_HOME="$SK_TMP/cfg2" PATH="$NOSYS" -- install --root "$ROOT"
assert_eq "$RC=$ERR1" "2=slack: systemctl-missing=run: systemctl --user daemon-reload && systemctl --user enable slack-listen.service && systemctl --user restart slack-listen.service" \
  "without systemctl the refusal names the commands to run"
assert_eq "$([ -f "$SK_TMP/cfg2/systemd/user/slack-listen.service" ] && echo present || echo absent)" "present" \
  "the unit is written before systemctl is looked for"
sk_run XDG_CONFIG_HOME="$SK_TMP/cfg3" PATH="$BIN:$PATH" FAKE_SYSTEMCTL_EXIT=3 -- install --root "$ROOT"
assert_eq "$RC=$ERR1" "2=slack: systemctl-failed=systemctl --user daemon-reload exit=3" "a failing systemctl is refused with its command and exit status"
BARE="$(sk_new_root bare)"
sk_run XDG_CONFIG_HOME="$CFG" -- install --root "$BARE" --print
assert_eq "$RC=$ERR1" "2=slack: root-unbound=$BARE" "an unbound root is refused before anything is written"
sk_run XDG_CONFIG_HOME="$CFG" -- install --print
assert_eq "$RC=${ERR1%%=*}" "2=slack: usage" "install with no --root is a usage refusal"

# --- controls, one mutant per rule --------------------------------------------------------------
sk_mutant roots verbs.py '\*\[f"--root \{r\}" for r in roots\]' '*[]'
sk_run XDG_CONFIG_HOME="$CFG" -- install --root "$ROOT" --print
assert_lacks "$OUT" "--root $ROOT" "control: the roots dropped from ExecStart, the unit names none"
sk_bin_reset

sk_mutant restart verbs.py '"try-restart", UNIT' '"is-active", UNIT'
: > "$LOG"
sk_run XDG_CONFIG_HOME="$CFG" PATH="$BIN:$PATH" -- setup --root "$ROOT"
assert_eq "$(cat "$LOG")" "--user is-active slack-listen.service" "control: the restart replaced, setup restarts nothing"
sk_bin_reset

sk_summary
