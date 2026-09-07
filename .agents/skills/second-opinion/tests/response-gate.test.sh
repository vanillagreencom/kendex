#!/usr/bin/env bash
# The response gate of a single-lane review: the shape of the first response
# and, when it earns a retry, of the second decides whether the artifact is
# written, the one-shot retry runs with the full original request, the run
# exits 3 (no scope), 4 (no review attested) or 1 (nothing parseable), and
# which sidecar keeps the rejected bytes. The written artifact carries the
# wrapper's own clock and the raw byte counts.
#
# A row is `label|world|argv|rc|out|err|state`; the world's words are the stub
# world's (lib/stub-cli-world.bash), `stdout:` the first response, `stdout2:`
# the second; every row captures its prompts. The state adds:
#   art=<agent>:<verdict>:<summary>:b=<blocker titles>:ts=<stamp>:raw=<bytes>:retry=<bytes|->:head=<head|->
#     (the artifact at --output, or on stdout in stdout mode; `-` when none)
#   scope=<branch>/<range>/<changed files>/<diff command>  (the first prompt's
#     scope block; `-` when the CLI never ran)
#   retry=<problem>:<scope of the retry prompt>:prev=<the embedded first response's class>
#     (`-` when no second call ran)

. "$(dirname "${BASH_SOURCE[0]}")/lib/stub-cli-world.bash"

artifact() {
  local file="$OUT"
  [[ "$W_OUTPUT" != - ]] || file="$ROW/stdout"
  [[ -s "$file" ]] || { printf -- '-'; return; }
  jq -r '"\(.agent):\(.verdict):\(.summary):b=\(.blockers | map(.title) | join(",")):ts=\(.timestamp):raw=\(.qa_metadata | if has("raw_response_bytes") then .raw_response_bytes else "-" end):retry=\(.qa_metadata | if has("retry_response_bytes") then .retry_response_bytes else "-" end):head=\(.qa_metadata | if has("reviewed_head") then .reviewed_head else "-" end)"' "$file" 2>/dev/null | alias_text
  [[ "${PIPESTATUS[0]}" -eq 0 ]] || printf 'not-json'
}

# The scope block of a prompt: branch, range, the changed files, the command.
scope_of() {
  local branch range files cmd
  branch="$(sed -n 's/^- Branch: //p' "$1")"
  range="$(sed -n 's/^- Diff range: //p' "$1")"
  files="$(sed -n '/^- Changed files:$/,/^$/{/^- Changed files:$/d;/^$/d;p;}' "$1" | paste -s -d ',' -)"
  cmd="$(sed -n 's/^  \(git diff .*\)$/\1/p' "$1")"
  printf '%s/%s/%s/%s' "${branch:--}" "${range:--}" "${files:--}" "${cmd:--}"
}

prompts() {
  local first="$ROW/prompts/prompt-1.txt" second="$ROW/prompts/prompt-2.txt" problem prev
  [[ -f "$first" ]] || { printf ' scope=- retry=-'; return; }
  printf ' scope=%s' "$(scope_of "$first" | alias_text)"
  [[ -f "$second" ]] || { printf ' retry=-'; return; }
  case "$(head -n 1 "$second")" in
    *"did not contain a parseable JSON object"*) problem=unparseable ;;
    *"missing required schema fields"*) problem=incomplete ;;
    *) problem=UNKNOWN-PROBLEM ;;
  esac
  sed -n '/^--- Your previous response ---$/,/^--- End of your previous response ---$/{//d;p;}' "$second" >"$ROW/prev"
  prev="$(content_class "$ROW/prev")"
  printf ' retry=%s:%s:prev=%s' "$problem" "$(scope_of "$second" | alias_text)" "$prev"
}

extra_state() {
  printf ' art=%s%s' "$(artifact)" "$(prompts)"
}

# The err words this table adds to the world's.
suite_err_word() {
  local -a f
  IFS=: read -r -a f <<<"$1"
  local a="${f[1]:-}" b="${f[2]:-}" c="${f[3]:-}"
  case "$1" in
    no-scope) printf 'error=No review scope: git diff <head> is empty — nothing to review cwd=<work> branch=scope-branch\n' ;;
    retrying:unparseable) printf '→ extract_json failed on first response; retrying once with captured response\n' ;;
    retrying:incomplete) printf '→ first response JSON is structurally incomplete; retrying once with captured response\n' ;;
    recovered:*) printf '→ retry recovered valid JSON (%s bytes)\n→ raw first response preserved: %s\n' "$a" "$(gate_record "$b" raw)" ;;
    # unparseable:<raw length>:<where the records landed>:<the first response's shape>
    unparseable:*) printf '→ retry response still not parseable\nerror=Failed to extract JSON from claude response after retry raw_length=%s raw_response=%s retry_response=%s\n→ retry response preserved: %s\n→ raw response preserved: %s\n--- First 30 lines of raw response ---\n%s\n' "$a" "$(gate_record "$b" raw)" "$(gate_record "$b" retry)" "$(gate_record "$b" retry)" "$(gate_record "$b" raw)" "$(stdout_of "prose:$c")" ;;
    still-incomplete) printf '→ retry response JSON is still structurally incomplete\n' ;;
    rejected:noreview:*) printf 'error=claude self-reported that no review was performed (%s) — refusing to write a review artifact response=<out>.noreview.json\n→ rejected response preserved: <out>.noreview.json\n' "$b" ;;
    rejected:noqa) printf 'error=claude returned non-conforming JSON with no qa_metadata object (missing_qa_metadata) — refusing to write a review artifact response=<out>.noreview.json\n→ rejected response preserved: <out>.noreview.json\n' ;;
    rejected:incomplete) printf 'error=claude returned structurally incomplete JSON after retry — verdict and the blockers/suggestions/questions arrays are required (incomplete_schema) — refusing to write a review artifact response=<out>.incomplete.json\n→ rejected response preserved: <out>.incomplete.json\n' ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s\n' "$1" ;;
  esac
}
# where a raw or retry record landed: out (the sidecar) or home (the row's home)
gate_record() {
  case "$1" in
    out) printf '<out>.%s.txt' "$2" ;;
    home) printf '%s/review-claude-%s.*' "$(record_home)" "$2" ;;
    *) printf 'UNKNOWN-RECORD-PATH:%s' "$1" ;;
  esac
}
DEFAULTS="capture"
run_table "the response gate" "$DEFAULTS" "\
a review that parses and attests is written, stamped with the wrapper's clock and the raw byte count|stdout:good|review|0|<out>|header:review written|calls=1 files=out=review:external-claude:Clean home=absent tmp=0 dirty=- art=external-claude:pass:Clean:b=:ts=$CLOCK:raw=160:retry=-:head=<head> scope=scope-branch/<head>/file.txt/git diff <head> retry=-
a review inside a json fence is the review, no retry|stdout:fenced|review|0|<out>|header:review written|calls=1 files=out=review:external-claude:Clean home=absent tmp=0 dirty=- art=external-claude:pass:Clean:b=:ts=$CLOCK:raw=207:retry=-:head=<head> scope=scope-branch/<head>/file.txt/git diff <head> retry=-
a review inside a bare fence is the review, no retry|stdout:fenced-bare|review|0|<out>|header:review written|calls=1 files=out=review:external-claude:Clean home=absent tmp=0 dirty=- art=external-claude:pass:Clean:b=:ts=$CLOCK:raw=203:retry=-:head=<head> scope=scope-branch/<head>/file.txt/git diff <head> retry=-
a self-reported review_performed=true is written|stdout:performed|review|0|<out>|header:review written|calls=1 files=out=review:external-claude:Reviewed the diff, no issues home=absent tmp=0 dirty=- art=external-claude:pass:Reviewed the diff, no issues:b=:ts=$CLOCK:raw=206:retry=-:head=<head> scope=scope-branch/<head>/file.txt/git diff <head> retry=-
an empty diff exits 3 before the CLI runs|diff:empty|review|3|-|header:review no-scope|calls=0 files=- home=absent tmp=0 dirty=- art=- scope=- retry=-
prose claiming an earlier turn is retried with the full request; the retry's review is written, the prose kept beside it|stdout:prose:delivered stdout2:blocker|review|0|<out>|header:review retrying:unparseable recovered:450:out written|calls=2 files=out=review:external-claude:One blocker found,out.raw.txt=prose:delivered home=absent tmp=0 dirty=- art=external-claude:action_required:One blocker found:b=Null deref in parser:ts=$CLOCK:raw=74:retry=348:head=<head> scope=scope-branch/<head>/file.txt/git diff <head> retry=unparseable:scope-branch/<head>/file.txt/git diff <head>:prev=prose:delivered
prose twice: exit 1, no artifact, both responses kept, the error names both|stdout:prose:sql stdout2:prose:previously|review|1|-|header:review retrying:unparseable unparseable:90:out:sql|calls=2 files=out.raw.txt=prose:sql,out.retry.txt=prose:previously home=absent tmp=0 dirty=- art=- scope=scope-branch/<head>/file.txt/git diff <head> retry=unparseable:scope-branch/<head>/file.txt/git diff <head>:prev=prose:sql
prose twice in stdout mode: the raw and retry records are two files in the home, nothing in TMPDIR|output:- stdout:prose:sql stdout2:prose:previously|review|1|-|header:review retrying:unparseable unparseable:90:home:sql|calls=2 files=- home=mode=700,review-claude-raw=prose:sql,review-claude-retry=prose:previously,ignore=* tmp=0 dirty=- art=- scope=scope-branch/<head>/file.txt/git diff <head> retry=unparseable:scope-branch/<head>/file.txt/git diff <head>:prev=prose:sql
prose, then a retry that admits no review: exit 4, the admission kept|stdout:prose:delivered stdout2:noreview|review|4|-|header:review retrying:unparseable recovered:330:out rejected:noreview:no_scope_provided|calls=2 files=out.noreview.json=review:external-claude:No review performed:no_scope_provided,out.raw.txt=prose:delivered home=absent tmp=0 dirty=- art=- scope=scope-branch/<head>/file.txt/git diff <head> retry=unparseable:scope-branch/<head>/file.txt/git diff <head>:prev=prose:delivered
prose, then a retry with no qa_metadata: exit 4|stdout:prose:delivered stdout2:noqa|review|4|-|header:review retrying:unparseable recovered:186:out rejected:noqa|calls=2 files=out.noreview.json=review:external-claude:Nothing to evaluate,out.raw.txt=prose:delivered home=absent tmp=0 dirty=- art=- scope=scope-branch/<head>/file.txt/git diff <head> retry=unparseable:scope-branch/<head>/file.txt/git diff <head>:prev=prose:delivered
a first response admitting no review: exit 4, no retry, the admission and its reason kept|stdout:noreview|review|4|-|header:review rejected:noreview:no_scope_provided|calls=1 files=out.noreview.json=review:external-claude:No review performed:no_scope_provided home=absent tmp=0 dirty=- art=- scope=scope-branch/<head>/file.txt/git diff <head> retry=-
a first response with no qa_metadata: exit 4, no retry|stdout:noqa|review|4|-|header:review rejected:noqa|calls=1 files=out.noreview.json=review:external-claude:Nothing to evaluate home=absent tmp=0 dirty=- art=- scope=scope-branch/<head>/file.txt/git diff <head> retry=-
finding arrays lost: retried naming the missing fields, the retry's review written|stdout:truncated stdout2:blocker|review|0|<out>|header:review retrying:incomplete recovered:450:out written|calls=2 files=out=review:external-claude:One blocker found,out.raw.txt=review:external-claude:Reviewed the diff, one issue noted home=absent tmp=0 dirty=- art=external-claude:action_required:One blocker found:b=Null deref in parser:ts=$CLOCK:raw=126:retry=348:head=<head> scope=scope-branch/<head>/file.txt/git diff <head> retry=incomplete:scope-branch/<head>/file.txt/git diff <head>:prev=review:external-claude:Reviewed the diff, one issue noted
blockers as a string is incomplete too: retried, the retry's review written|stdout:blockers-string stdout2:blocker|review|0|<out>|header:review retrying:incomplete recovered:450:out written|calls=2 files=out=review:external-claude:One blocker found,out.raw.txt=review:external-claude:ok home=absent tmp=0 dirty=- art=external-claude:action_required:One blocker found:b=Null deref in parser:ts=$CLOCK:raw=161:retry=348:head=<head> scope=scope-branch/<head>/file.txt/git diff <head> retry=incomplete:scope-branch/<head>/file.txt/git diff <head>:prev=review:external-claude:ok
finding arrays lost, then blockers as a string: exit 4, the retry kept as the incomplete sidecar, the first as the raw|stdout:truncated stdout2:blockers-string|review|4|-|header:review retrying:incomplete still-incomplete rejected:incomplete|calls=2 files=out.incomplete.json=review:external-claude:ok,out.raw.txt=review:external-claude:Reviewed the diff, one issue noted home=absent tmp=0 dirty=- art=- scope=scope-branch/<head>/file.txt/git diff <head> retry=incomplete:scope-branch/<head>/file.txt/git diff <head>:prev=review:external-claude:Reviewed the diff, one issue noted
"
finish
