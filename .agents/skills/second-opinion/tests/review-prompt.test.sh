#!/usr/bin/env bash
# The review prompt: its lens list, the output schema, the diff embedded for a
# target whose SECOND_OPINION_<NAME>_INLINE_DIFF is 1 and for no other, and the repository's
# own instruction files appended to it, chosen by the setting's globs (the
# default set, a custom list, the empty list), with the nested AGENTS.md
# files governing the changed paths after their parents, symlinks and
# outside paths refused, a dash-leading directory resolved, BSD utilities
# that reject `--` still building the whole prompt, and each pattern that
# matches no file, and a prompt left with none, reported on stderr.
#
# The script runs from a hermetic copy of the skill (the checkout's own
# settings would decide the globs otherwise); a row with a `settings:` word
# writes that copy's kendex.settings.toml for the run.
#
# A row is `label|world|argv|rc|out|err|state`; the world's words are the stub
# world's (lib/stub-cli-world.bash) plus:
#   layout:<full|evil|dash|botrender>  the reviewed repository's instruction files
#   committed                a committed file, the world's edit left uncommitted
#   bigdiff                  a staged file whose diff runs past the inline cap
#   bigdel                   bigdiff, and a committed file deleted after it
#   settings:<globs>         the project settings' SECOND_OPINION_REVIEW_INSTRUCTIONS
#   bsd                      sed, head, stat, cat, basename and dirname refusing `--`
# The state adds:
#   lenses=<the lens names in the prompt's order>[+bash3.2 when the portability lens names it]
#   skip=<what the prompt says to skip>
#   schema=[json-only:]<the verdict line of the output schema, or ->
#   instr=<path(RULE),...> the instruction block's files in the prompt's order,
#     each with the rule token its content carries (`?` for content under no
#     header); `-` when the block is absent, `empty` when it holds nothing
#   miss=<glob,...|->  the patterns reported as matching no file, in order
#   none=<N|->  the pattern count the no-instructions report names
#   head=<head|->  the artifact's reviewed head
#   diff=<line,...|->  the added lines of the embedded diff, `-` when none is
#   paged=<mode>:<line,...>  when the embedded diff was cut, the mode and the
#     removed lines of the whole-diff file its marker names, as the reviewer
#     read it mid-run

. "$(dirname "${BASH_SOURCE[0]}")/lib/stub-cli-world.bash"
. "$(dirname "${BASH_SOURCE[0]}")/lib/install.bash"

# The hermetic copy: a repository of its own, no settings file.
PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ/skills"
git init -q "$PROJ"
second_opinion_install "$SKILL_DIR" "$PROJ/skills"
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
    # only the file the bot-instructions skill renders
    layout:botrender)
      mkdir -p "$WORK/.github/instructions"
      printf 'RULE-GOLF: rendered review rule\n' >"$WORK/.github/instructions/code-review.md"
      ;;
    # a committed change a range can name, beside the world's own uncommitted
    # edit, so the range's diff and the working tree's differ
    committed)
      printf 'committed\n' >"$WORK/pinned.txt"
      git -C "$WORK" add pinned.txt
      git -C "$WORK" -c commit.gpgsign=false commit -q -m pinned
      HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)"
      ;;
    # a diff past the inline cap: an added line, one line long enough to cross
    # the cap, and a line after it
    bigdiff)
      { printf 'first\n'; head -c 140000 /dev/zero | tr '\0' x; printf '\nlast\n'; } >"$WORK/zbig.txt"
      git -C "$WORK" add zbig.txt
      ;;
    # a deletion past the cap: a committed file the working tree removes,
    # sorted after the long file
    bigdel)
      printf 'gone\n' >"$WORK/zgone.txt"
      git -C "$WORK" add zgone.txt
      git -C "$WORK" -c commit.gpgsign=false commit -q -m gone
      HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)"
      suite_word bigdiff
      rm "$WORK/zgone.txt"
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

# The instruction-file reports on the run's stderr: miss=<patterns> none=<N>.
reports() {
  local line miss="" none=""
  while IFS= read -r line; do
    case "$line" in
      "second-opinion: instructions-unmatched pattern="*) miss="$miss,${line#*pattern=}" ;;
      "second-opinion: instructions-none patterns="*) none="${line#*patterns=}" ;;
    esac
  done <"$ROW/stderr"
  miss="${miss#,}"
  printf 'miss=%s none=%s' "${miss:--}" "${none:--}"
}

# The embedded diff: its added lines, `+++` headers aside, and its truncation
# marker, the whole diff's file under <work> with its mktemp suffix as `*`.
inline_diff() {
  local added
  added="$(sed -n '/^--- begin diff ---$/,/^--- end diff ---$/{/^+[^+]/p;/^\[diff truncated/p;}' "$1" \
    | sed -e "s|$WORK|<work>|g" -e 's/-diff\.[A-Za-z0-9]\{6\}\]$/-diff.*]/' | paste -s -d ',' -)"
  printf '%s' "${added:--}"
}

# The whole-diff file the stub paged: its mode and removed lines.
paged() {
  local removed
  [[ -f "$ROW/prompts/paged-1.txt" ]] || return 0
  removed="$(sed -n '/^-[^-]/p' "$ROW/prompts/paged-1.txt" | paste -s -d ',' -)"
  printf ' paged=%s:%s' "$(cat "$ROW/prompts/paged-1.mode")" "${removed:--}"
}

extra_state() {
  local p="$ROW/prompts/prompt-1.txt" head
  head="$(jq -r '.qa_metadata.reviewed_head // "-"' "$OUT" 2>/dev/null | alias_text)"
  [[ -f "$p" ]] || { printf ' prompt=- %s head=%s' "$(reports)" "${head:--}"; return; }
  printf ' lenses=%s skip=%s schema=%s instr=%s %s head=%s diff=%s%s' "$(lenses "$p")" "$(skip_line "$p")" "$(schema_line "$p")" "$(instructions "$p")" "$(reports)" "${head:--}" "$(inline_diff "$p")" "$(paged)"
}

L="Correctness,Security and fail-open behavior,Adversarial inputs,Portability,Repo-rule adherence,Docs-vs-code drift,Test adequacy+bash3.2"
SKIP="pure style/formatting preferences and minor naming opinions"
SCHEMA="json-only:pass or action_required"
FULL="AGENTS.md(RULE-AGENTS),review-bots.md(RULE-ALPHA),.github/instructions/shell.instructions.md(RULE-BRAVO),.github/copilot-instructions.md(RULE-CHARLIE),services/AGENTS.md(RULE-SERVICES),services/api/AGENTS.md(RULE-NESTED)"
OK="0|<out>|header:review written|calls=1 files=out=review:external-claude:Clean home=absent tmp=0 dirty=-"
ALLMISS="AGENTS.md,review-bots.md,.github/instructions/code-review.md,.github/instructions/*.instructions.md,.github/copilot-instructions.md"
run_table "the review prompt" "capture" "\
the default globs: every matching file in the setting's order, the nested AGENTS.md files over a changed path parents first, the non-matching file left out, the unmatched default pattern reported|layout:full|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=$FULL miss=.github/instructions/code-review.md none=- head=<head> diff=-
no instruction files: no block, every default pattern and the empty prompt reported, the lenses and the schema still|-|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=- miss=$ALLMISS none=5 head=<head> diff=-
the default globs collect the bot-instructions render alone|layout:botrender|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=.github/instructions/code-review.md(RULE-GOLF) miss=AGENTS.md,review-bots.md,.github/instructions/*.instructions.md,.github/copilot-instructions.md none=- head=<head> diff=-
a custom glob list replaces the defaults|layout:full env:SECOND_OPINION_REVIEW_INSTRUCTIONS=docs/rules/*.md|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=docs/rules/custom.md(RULE-DELTA) miss=- none=- head=<head> diff=-
a pattern naming a missing file is reported and the review still runs|layout:full env:SECOND_OPINION_REVIEW_INSTRUCTIONS=docs/missing.md|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=- miss=docs/missing.md none=1 head=<head> diff=-
a missing pattern beside a matching one is reported, the matching file still appended|layout:full env:SECOND_OPINION_REVIEW_INSTRUCTIONS=review-bots.md,docs/missing.md|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=review-bots.md(RULE-ALPHA) miss=docs/missing.md none=- head=<head> diff=-
a directory-only pattern beside a matching one is reported, the matching file still appended|layout:full env:SECOND_OPINION_REVIEW_INSTRUCTIONS=review-bots.md,docs/rules|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=review-bots.md(RULE-ALPHA) miss=docs/rules none=- head=<head> diff=-
an empty setting drops the block and reports nothing|layout:full env:SECOND_OPINION_REVIEW_INSTRUCTIONS=|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=- miss=- none=- head=<head> diff=-
the project settings' globs reach the run|layout:full settings:review-bots.md|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=review-bots.md(RULE-ALPHA) miss=- none=- head=<head> diff=-
the caller's empty setting beats the project's|layout:full settings:review-bots.md env:SECOND_OPINION_REVIEW_INSTRUCTIONS=|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=- miss=- none=- head=<head> diff=-
a symlinked file and a file through a symlinked directory are refused by name, the regular file beside them appended|layout:evil|review|0|<out>|header:review skip-link:review-bots.md skip-outside:.github/instructions/leak.instructions.md written|calls=1 files=out=review:external-claude:Clean home=absent tmp=0 dirty=- lenses=$L skip=$SKIP schema=$SCHEMA instr=.github/copilot-instructions.md(RULE-ECHO) miss=AGENTS.md,.github/instructions/code-review.md none=- head=<head> diff=-
a changed path under a dash-leading directory finds its AGENTS.md|layout:dash|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=-svc/AGENTS.md(RULE-DASHDIR) miss=$ALLMISS none=- head=<head> diff=-
a target set to inline its diff gets the pinned range's diff in its scope block, not the working tree's, the prompt otherwise the same|committed env:SECOND_OPINION_CLAUDE_INLINE_DIFF=1|review --range HEAD~1...HEAD|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=- miss=$ALLMISS none=5 head=<head> diff=+committed
a diff past the cap is cut at its last whole line inside it and ends with a marker naming what was omitted and the whole diff's file, gone from the artifact home once the run ends|bigdiff env:SECOND_OPINION_CLAUDE_INLINE_DIFF=1|review|0|<out>|header:review written|calls=1 files=out=review:external-claude:Clean home=mode=700,ignore=* tmp=0 dirty=- lenses=$L skip=$SKIP schema=$SCHEMA instr=- miss=$ALLMISS none=5 head=<head> diff=+world,+first,[diff truncated at the 131072-byte cap: the remaining 140008 of its 140258 bytes are omitted; page them with your read tools from the whole diff, kept until this review ends at: <work>/tmp/second-opinion/review-claude-diff.*] paged=-rw-------:-
a deletion past the cap is in the owner-only file the marker names, readable while the review runs|bigdel env:SECOND_OPINION_CLAUDE_INLINE_DIFF=1|review|0|<out>|header:review written|calls=1 files=out=review:external-claude:Clean home=mode=700,ignore=* tmp=0 dirty=- lenses=$L skip=$SKIP schema=$SCHEMA instr=- miss=$ALLMISS none=5 head=<head> diff=+world,+first,[diff truncated at the 131072-byte cap: the remaining 140141 of its 140391 bytes are omitted; page them with your read tools from the whole diff, kept until this review ends at: <work>/tmp/second-opinion/review-claude-diff.*] paged=-rw-------:-gone
another target's setting leaves this target's prompt without the diff|env:SECOND_OPINION_CODEX_INLINE_DIFF=1|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=- miss=$ALLMISS none=5 head=<head> diff=-
BSD utilities that refuse -- still build the whole prompt|layout:full bsd|review|$OK lenses=$L skip=$SKIP schema=$SCHEMA instr=$FULL miss=.github/instructions/code-review.md none=- head=<head> diff=-
"
finish
