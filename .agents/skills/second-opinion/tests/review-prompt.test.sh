#!/usr/bin/env bash
# The review prompt: its lens list, the output schema, and the repository's
# own instruction files appended to it, chosen by the setting's globs (the
# default set, a custom list, the empty list), with the nested AGENTS.md
# files governing the changed paths after their parents, symlinks and
# outside paths refused, a dash-leading directory resolved, and BSD utilities
# that reject `--` still building the whole prompt.
#
# The script runs from a hermetic copy of the skill (the checkout's own
# settings would decide the globs otherwise); a row with a `settings:` word
# writes that copy's kendex.settings.toml for the run.
#
# A row is `label|world|argv|rc|out|err|state`; the world's words are the stub
# world's (lib/stub-cli-world.bash) plus:
#   layout:<full|evil|dash>  the reviewed repository's instruction files
#   settings:<globs>         the project settings' SECOND_OPINION_REVIEW_INSTRUCTIONS
#   bsd                      sed, head, stat, cat, basename and dirname refusing `--`
# The state adds:
#   lenses=<the lens names in the prompt's order>[+bash3.2 when the portability lens names it]
#   skip=<what the prompt says to skip>
#   schema=[json-only:]<the verdict line of the output schema, or ->
#   instr=<path(RULE),...> the instruction block's files in the prompt's order,
#     each with the rule token its content carries (`?` for content under no
#     header); `-` when the block is absent, `empty` when it holds nothing
#   head=<head|->  the artifact's reviewed head

. "$(dirname "${BASH_SOURCE[0]}")/lib/stub-cli-world.bash"

# The hermetic copy: a repository of its own, no settings file.
PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ/skills"
git init -q "$PROJ"
cp -R "$SKILL_DIR" "$PROJ/skills/second-opinion"
HERMETIC="$PROJ/skills/second-opinion/scripts/second-opinion"

# BSD utilities that read `--` as a file operand.
BSDBIN="$TMP_ROOT/bsdbin"
mkdir -p "$BSDBIN"
for u in sed head stat cat basename dirname; do
  real="$(command -v "$u" 2>/dev/null)" || continue
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # the shim expands them, which is the point
    printf 'for a in "$@"; do [[ "$a" == "--" ]] && { echo "%s: --: No such file or directory" >&2; exit 1; }; done\n' "$u"
    printf 'exec %q "$@"\n' "$real"
  } >"$BSDBIN/$u"
  chmod +x "$BSDBIN/$u"
done

suite_reset() {
  W_SCRIPT="$HERMETIC"
  rm -f "$PROJ/kendex.settings.toml"
}

suite_word() {
  case "$1" in
    # every default glob matched, two nested AGENTS.md over a changed path, a
    # non-matching file beside a matching one, a file for a custom glob
    layout:full)
      printf 'RULE-ALPHA: never merge on red CI\n' >"$WORK/review-bots.md"
      printf 'RULE-AGENTS: dev agents must run the suite\n' >"$WORK/AGENTS.md"
      mkdir -p "$WORK/services/api" "$WORK/.github/instructions" "$WORK/docs/rules"
      printf 'RULE-SERVICES: services log in JSON\n' >"$WORK/services/AGENTS.md"
      printf 'RULE-NESTED: api handlers must be idempotent\n' >"$WORK/services/api/AGENTS.md"
      printf 'handler' >"$WORK/services/api/handler.txt"
      git -C "$WORK" add services/api/handler.txt
      printf 'changed' >>"$WORK/services/api/handler.txt"
      printf 'RULE-BRAVO: quote all shell expansions\n' >"$WORK/.github/instructions/shell.instructions.md"
      printf 'RULE-NOMATCH: not an instructions file\n' >"$WORK/.github/instructions/notes.md"
      printf 'RULE-CHARLIE: keep docs in sync with code\n' >"$WORK/.github/copilot-instructions.md"
      printf 'RULE-DELTA: custom glob rule\n' >"$WORK/docs/rules/custom.md"
      ;;
    # a symlinked file, and a symlinked directory pointing outside the repo
    # with a matching file in it, beside a regular file
    layout:evil)
      printf 'SECRET-HOST-DATA: not for the prompt\n' >"$ROW/outside-secret.txt"
      printf 'SECRET-HOST-DATA: not for the prompt\n' >"$ROW/leak.instructions.md"
      ln -s "$ROW/outside-secret.txt" "$WORK/review-bots.md"
      mkdir -p "$WORK/.github"
      ln -s "$ROW" "$WORK/.github/instructions"
      printf 'RULE-ECHO: a legitimate rule\n' >"$WORK/.github/copilot-instructions.md"
      ;;
    # a changed path under a dash-leading directory with its own AGENTS.md
    layout:dash)
      mkdir -p "$WORK/-svc"
      printf 'RULE-DASHDIR: rules for the dashed service\n' >"$WORK/-svc/AGENTS.md"
      printf 'x\n' >"$WORK/-svc/code.txt"
      git -C "$WORK" add -A
      git -C "$WORK" -c commit.gpgsign=false commit -q -m dash
      HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)"
      printf 'y\n' >>"$WORK/-svc/code.txt"
      ;;
    settings:*) printf '[env]\nSECOND_OPINION_REVIEW_INSTRUCTIONS = "%s"\n' "${1#settings:}" >"$PROJ/kendex.settings.toml" ;;
    bsd) W_ENV+=("PATH=$BSDBIN:$TMP_ROOT/psbin:$TMP_ROOT/bin:$PATH") ;;
    *) echo "UNKNOWN-WORD: $1" >&2; exit 2 ;;
  esac
}

suite_err_word() {
  case "$1" in
    skip-link:*) printf '→ skipping symlinked instruction file (must be a regular file inside the repo): %s\n' "${1#skip-link:}" ;;
    skip-outside:*) printf '→ skipping instruction file outside the reviewed repo: %s -> <row>\n' "${1#skip-outside:}" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s\n' "$1" ;;
  esac
}

skip_line() {
  sed -n 's/^Skip only \(.*\)\.$/\1/p' "$1"
}
# The schema: its instruction line and its verdict line.
schema_line() {
  local v only=""
  ! grep -q '^Output ONLY valid JSON' "$1" || only="json-only:"
  v="$(sed -n 's/^ *"verdict": "\(.*\)",*$/\1/p' "$1" | head -n 1)"
  printf '%s%s' "$only" "${v:--}"
}
# The lens names in order, and the portability lens's Bash line.
lenses() {
  local bash32=""
  ! grep -q '^- Portability: Bash 3.2 compatibility' "$1" || bash32="+bash3.2"
  sed -n '/^Review the diff through ALL of these lenses/,/^Skip only/{s/^- \([^:]*\):.*/\1/p;}' "$1" | paste -s -d ',' - | tr -d '\n'
  printf '%s' "$bash32"
}
# The instruction block: each `--- path ---` header with the rule token of
# the content under it.
instructions() {
  local line entry="" out="" in_block=""
  while IFS= read -r line; do
    if [[ -z "$in_block" ]]; then
      [[ "$line" == "Repository review instructions"* ]] && in_block=1
      continue
    fi
    case "$line" in
      "--- "*" ---") [[ -z "$entry" ]] || out="$out,$entry)"; entry="${line#--- }"; entry="${entry% ---}("; ;;
      "") ;;
      # content: the rule token under its header, or under `?` with no header
      *) [[ -n "$entry" ]] || entry="?("
         case "$entry" in *"(") entry="$entry${line%%:*}" ;; esac ;;
    esac
  done <"$1"
  [[ -z "$entry" ]] || out="$out,$entry)"
  # no block at all, a block with nothing under it, or its files
  [[ -n "$in_block" ]] || { printf -- '-'; return; }
  printf '%s' "${out:+${out#,}}"
  [[ -n "$out" ]] || printf 'empty'
}

extra_state() {
  local p="$ROW/prompts/prompt-1.txt" head
  head="$(jq -r '.qa_metadata.reviewed_head // "-"' "$OUT" 2>/dev/null | alias_text)"
  [[ -f "$p" ]] || { printf ' prompt=- head=%s' "${head:--}"; return; }
  printf ' lenses=%s skip=%s schema=%s instr=%s head=%s' "$(lenses "$p")" "$(skip_line "$p")" "$(schema_line "$p")" "$(instructions "$p")" "${head:--}"
}

L="Correctness,Security and fail-open behavior,Adversarial inputs,Portability,Repo-rule adherence,Docs-vs-code drift,Test adequacy+bash3.2"
SKIP="pure style/formatting preferences and minor naming opinions"
SCHEMA="json-only:pass or action_required"
FULL="AGENTS.md(RULE-AGENTS),review-bots.md(RULE-ALPHA),.github/instructions/shell.instructions.md(RULE-BRAVO),.github/copilot-instructions.md(RULE-CHARLIE),services/AGENTS.md(RULE-SERVICES),services/api/AGENTS.md(RULE-NESTED)"
OK="0|<out>|header:review written|calls=1 files=out=review:external-claude:Clean home=absent tmp=0 dirty=-"
run_table "the review prompt" "capture" "\
the default globs: every matching file in the setting's order, the nested AGENTS.md files over a changed path parents first, the non-matching file left out|layout:full|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=$FULL head=<head>
no instruction files: no block, the lenses and the schema still|-|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=- head=<head>
a custom glob list replaces the defaults|layout:full env:SECOND_OPINION_REVIEW_INSTRUCTIONS=docs/rules/*.md|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=docs/rules/custom.md(RULE-DELTA) head=<head>
an empty setting drops the block|layout:full env:SECOND_OPINION_REVIEW_INSTRUCTIONS=|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=- head=<head>
the project settings' globs reach the run|layout:full settings:review-bots.md|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=review-bots.md(RULE-ALPHA) head=<head>
the caller's empty setting beats the project's|layout:full settings:review-bots.md env:SECOND_OPINION_REVIEW_INSTRUCTIONS=|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=- head=<head>
a symlinked file and a file through a symlinked directory are refused by name, the regular file beside them appended|layout:evil|review|0|<out>|header:review skip-link:review-bots.md skip-outside:.github/instructions/leak.instructions.md written|calls=1 files=out=review:external-claude:Clean home=absent tmp=0 dirty=- lenses=$L skip=$SKIP schema=$SCHEMA instr=.github/copilot-instructions.md(RULE-ECHO) head=<head>
a changed path under a dash-leading directory finds its AGENTS.md|layout:dash|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=-svc/AGENTS.md(RULE-DASHDIR) head=<head>
BSD utilities that refuse -- still build the whole prompt|layout:full bsd|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=$FULL head=<head>
"
finish
