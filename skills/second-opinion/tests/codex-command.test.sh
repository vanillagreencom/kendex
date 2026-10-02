#!/usr/bin/env bash
# Pin the argv the built-in Codex target receives: `--disable hooks` keeps the
# project's Codex hooks out of the nested review.
. "$(dirname "${BASH_SOURCE[0]}")/lib/roster-world.bash"
EXPECTED=$'exec\n-m\ngpt-6.1-sol\n-s\nread-only\n-c\nmodel_reasoning_effort=xhigh\n--disable\nhooks\n--ephemeral'
for row in pin control; do
  build "$row" current:none models:codex
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s/argv"\nexec "%s/bin/lane-codex" "$@"\n' "$ROW" "$ROW" >"$ROW/bin/codex"
  chmod +x "$ROW/bin/codex"
  # The control retains the flag text but removes it from the executable default.
  [[ "$row" == pin ]] || python3 -c 'import pathlib, sys; p = pathlib.Path(sys.argv[1]); t = p.read_text(); old = " --disable hooks --ephemeral\""; assert not p.is_symlink() and t.count(old) == 1; p.write_text(t.replace(old, " --ephemeral\" # retained control text: --disable hooks"))' "$SO"
  rc=0
  env -i HOME="$ROW" PATH="$ROW/bin:$PATH" ${W_ENV[@]+"${W_ENV[@]}"} "$SO" quick --cwd "$WORK" --output "$ROW/out/out.json" "inspect file.txt" >"$ROW/stdout" 2>"$ROW/stderr" || rc=$?
  assert_eq "$rc" 0 "$row run returns a usable reply"
  if [[ "$row" == pin ]]; then assert_eq "$(cat "$ROW/argv")" "$EXPECTED" "default codex argv disables hooks"; continue; fi
  control_rc=0
  (assert_eq "$(cat "$ROW/argv")" "$EXPECTED" "must-fail: no --disable hooks"; [[ "$FAIL" -eq 0 ]]) || control_rc=$?
  assert_eq "$control_rc" 1 "removing --disable hooks turns the argv pin red"
done
finish
