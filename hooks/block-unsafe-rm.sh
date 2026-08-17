#!/usr/bin/env bash
# ---
# name: block-unsafe-rm
# event: PreToolUse
# matcher: Bash
# description: Block a recursive rm whose path starts with a variable that may expand empty. Names the rewrite the harness accepts without a prompt.
# safety: The harness stops the whole session on that shape with a "Dangerous rm operation on possibly-empty variable path" prompt; refusing it here lets the agent rewrite and continue.
# harnesses: [claude-code, cursor, opencode, codex]
# ---

set -euo pipefail

# Read stdin with the shell builtin so the fast exit forks nothing.
INPUT=''
_line=''
while IFS= read -r _line || [ -n "$_line" ]; do
  INPUT="$INPUT$_line"
done

# Fast exit on every Bash call that carries no rm at all.
case "$INPUT" in
  *rm*) ;;
  *) exit 0 ;;
esac

# Both decode paths lean on the text tools under set -e — segmenting and
# flag folding run either way — so an rm-bearing payload on a PATH missing
# any of them refuses up front instead of dying mid-scan or slipping through.
if ! command -v grep >/dev/null 2>&1 || ! command -v sed >/dev/null 2>&1 \
  || ! command -v head >/dev/null 2>&1 || ! command -v awk >/dev/null 2>&1 \
  || ! command -v tr >/dev/null 2>&1; then
  echo "block-unsafe-rm: text tools (grep/sed/head/awk/tr) unavailable to scan the payload; refusing rather than skipping the guard" >&2
  exit 2
fi

if command -v jq >/dev/null 2>&1; then
  # A payload that does not parse is refused, not skipped: an unreadable
  # command cannot be proven safe, and this guard is fail-closed by design.
  if ! COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // empty' 2>/dev/null); then
    echo "block-unsafe-rm: hook payload is not valid JSON; refusing rather than skipping the guard" >&2
    exit 2
  fi
else
  # Escape-aware fallback: the value may carry \" and \\ inside it.
  COMMAND=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"\([^"\\]\|\\.\)*"' | head -1 \
    | sed 's/^"command"[[:space:]]*:[[:space:]]*"//;s/"$//;s/\\"/"/g;s/\\\\/\\/g' 2>/dev/null || true)
  # Same fail-closed contract as the jq branch: a payload that names a
  # command the fallback could not decode (e.g. an unterminated string) is
  # refused, not skipped. A decoded-empty command ("command":"") still passes.
  if [ -z "$COMMAND" ] \
    && printf '%s' "$INPUT" | grep -q '"command"' \
    && ! printf '%s' "$INPUT" | grep -Eq '"command"[[:space:]]*:[[:space:]]*""'; then
    echo "block-unsafe-rm: could not decode the command from the hook payload; refusing rather than skipping the guard" >&2
    exit 2
  fi
fi

# One rm invocation per line: split on command separators, then keep the
# segments that start with rm (optionally under sudo/env prefixes are out of
# scope — the shape the harness prompts on is a plain rm). Tabs count as the
# word separators they are, and a leading subshell/group/substitution opener
# is peeled so `(rm …` and `$(rm …` classify like `rm …`. awk, not sed: a
# newline in a sed replacement is a GNU extension BSD sed lacks, and this
# hook runs on the macOS Bash 3.2 target too.
SEGMENTS=$(printf '%s\n' "$COMMAND" \
  | awk '{ blob = blob $0 "\n" }
      END {
        gsub(/\t/, " ", blob); gsub(/\\t/, " ", blob)
        gsub(/\\n/, "\n", blob)
        # A backslash-newline is a continuation of ONE shell word list, so it
        # folds to a space before the separator split.
        gsub(/\\\n/, " ", blob)
        # Every ; | & separates commands — the doubled forms collapse into
        # an empty segment between two newlines, which matches nothing. A
        # closing paren separates too, so a case-arm body (`x) rm …;;`) and
        # a subshell tail become their own segments.
        gsub(/[;|&)]/, "\n", blob)
        printf "%s", blob
      }')

while IFS= read -r seg; do
  # Peel whatever can stand between a separator and the command word:
  # subshell/group/substitution openers and the shell control keywords, so
  # `then rm …`, `do rm …`, and `( rm …` all classify as `rm …`.
  while :; do
    case "$seg" in
      [[:space:]]* | '('* | '{'* | '$'* | '`'*)
        seg=$(printf '%s' "$seg" | sed 's/^[[:space:]({$`]*//') ;;
      then\ * | do\ * | else\ * | elif\ * | if\ * | while\ * | until\ * | time\ * | '!'\ *)
        seg=${seg#* } ;;
      *) break ;;
    esac
  done
  case "$seg" in
    rm\ *) ;;
    *) continue ;;
  esac
  # Recursive form: -r/-R anywhere in a short-option cluster, or --recursive.
  # Quoting and escaping do not change what rm receives — `rm "-rf"`,
  # `rm -r""f`, and `rm -\rf` all pass -rf — so the flag scan reads a copy
  # with quotes and backslashes folded away.
  flat=$(printf '%s' "$seg" | tr -d "\"'\\\\")
  printf '%s' "$flat" | grep -Eq '(^|[[:space:]])(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)([[:space:]]|$)' || continue
  # A redirection target belongs to the shell, never to rm: the operator and
  # its target drop out before operand classification, so `> $LOG` on a
  # literal-path rm is not a variable root.
  seg=$(printf '%s' "$seg" | sed -E 's/[0-9]*(>>?|<<<|<<|<)[[:space:]]*[^[:space:]]+//g')
  # Any operand (not an option) that begins with a variable expansion whose
  # value can be empty: $NAME, ${NAME}, "$NAME/…", ${NAME:-…}. The one form
  # that cannot expand empty is ${NAME:?…}, which the harness accepts.
  # Globbing is off around the unquoted split so a `*` in the command stays a
  # literal token instead of expanding against the hook's cwd; `--` ends
  # option skipping, and a post-`--` operand sheds leading dashes for
  # classification so `-$DIR/sub` is still a variable root.
  set -f
  seen_ddash=0
  for tok in $seg; do
    if [ "$seen_ddash" -eq 0 ]; then
      case "$tok" in
        --) seen_ddash=1; continue ;;
        -*) continue ;;
      esac
    fi
    # Leading EMPTY quote pairs contribute nothing to the word — `""$X` and
    # `''$X` are still variable roots — so they peel off repeatedly. After
    # that only a double quote is peeled: a single-quoted run is a literal
    # the shell never expands, so it is not a variable root.
    stripped=$tok
    while :; do
      case "$stripped" in
        \$\'\'*) stripped=${stripped#\$\'\'} ;;
        \"\"*) stripped=${stripped#\"\"} ;;
        \'\'*) stripped=${stripped#\'\'} ;;
        *) break ;;
      esac
    done
    stripped=${stripped#\"}
    if [ "$seen_ddash" -eq 1 ]; then
      while [ "${stripped#-}" != "$stripped" ]; do stripped=${stripped#-}; done
    fi
    case "$stripped" in
      \$\'*) continue ;;               # $'…' is an ANSI-C literal, not a variable
      \$\{[A-Za-z_]*:\?*)
        # Safe only when everything before the first :? is a plain
        # identifier: ${NAME:?} aborts on empty, but ${X+x:?} is an
        # unset-guarded ALTERNATIVE whose text merely contains :? and can
        # still expand empty.
        _name=${stripped#??}
        _name=${_name%%:\?*}
        case "$_name" in
          *[!A-Za-z0-9_]*) ;;   # not ${IDENTIFIER:?} — falls through below
          *) continue ;;        # ${NAME:?} — cannot expand empty
        esac
        ;;
    esac
    case "$stripped" in
      \$*)
        {
          echo "Recursive rm on a variable-rooted path stalls the session: the harness stops on"
          echo "  $tok"
          echo "with a 'Dangerous rm operation on possibly-empty variable path' prompt."
          echo "Rewrite so the path cannot collapse to / — either form is accepted:"
          echo "  rm -rf -- \"\${NAME:?}/sub\"      (bash aborts if NAME is unset or empty)"
          echo "  rm -rf -- /absolute/literal/path"
        } >&2
        exit 2
        ;;
    esac
  done
  set +f
done <<<"$SEGMENTS"

exit 0
