#!/usr/bin/env bash
# issues remove-relation keeps a blocking relation whose blocker is Done or
# Canceled: that relation is satisfied history, ../SKILL.md § Blocked Label vs Issue Relations
# says, refused before any write with one keyed line. The one
# removal route is --peer-rule-violation, tpm-audit's structural repair, which
# passes only for a pair the rule refuses. Inputs: scripts/commands/issues.sh,
# scripts/lib/issue-validation.sh through the shipped linear.sh command.
#
# Fixture: CC-11 is a top-level container; CC-12 is a top-level leaf. CC-1 is a
# bundle parent.
#   CC-10  Done, top-level         rel ...01
#   CC-20  Canceled, top-level     rel ...02
#   CC-30  In Progress, top-level  rel ...03
#   CC-40  Done, child of CC-1     rel ...04  (crosses bundles with CC-11)
#   CC-50  related to CC-11        rel ...05
#   CC-60  Done, top-level         rel ...06  (its relation read fails)
#   CC-70  "Done | shipped", top-level  rel ...07
#   CC-40  Done, child of CC-1 blocks leaf CC-12  rel ...08

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
git -C "$TMP_ROOT" init -q -b main

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
payload=$(sed -n 's/^data = //p' <<<"$(cat)" | jq -r)
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
jq -cj '
  def page($nodes): {pageInfo: {hasNextPage: false, endCursor: null}, nodes: $nodes};
  def node($id; $state; $type; $parent):
    {id: ("uuid-" + $id), identifier: $id, title: "t", state: {name: $state, type: $type},
     parent: (if $parent then {identifier: $parent, parent: null} else null end),
     children: {nodes: (if $id == "CC-11" then [{id:"child"}] else [] end), pageInfo: {hasNextPage:false}}};
  def issues: {
    "CC-10": node("CC-10"; "Done"; "completed"; null),
    "CC-11": node("CC-11"; "Todo"; "unstarted"; null),
    "CC-12": node("CC-12"; "Todo"; "unstarted"; null),
    "CC-20": node("CC-20"; "Canceled"; "canceled"; null),
    "CC-30": node("CC-30"; "In Progress"; "started"; null),
    "CC-40": node("CC-40"; "Done"; "completed"; "CC-1"),
    "CC-50": node("CC-50"; "Todo"; "unstarted"; null),
    "CC-60": node("CC-60"; "Done"; "completed"; null),
    "CC-70": node("CC-70"; "Done | shipped"; "completed"; null)};
  def rels: [
    {id: "00000000-0000-4000-8000-000000000001", type: "blocks", from: "CC-10", to: "CC-11"},
    {id: "00000000-0000-4000-8000-000000000002", type: "blocks", from: "CC-20", to: "CC-11"},
    {id: "00000000-0000-4000-8000-000000000003", type: "blocks", from: "CC-30", to: "CC-11"},
    {id: "00000000-0000-4000-8000-000000000004", type: "blocks", from: "CC-40", to: "CC-11"},
    {id: "00000000-0000-4000-8000-000000000005", type: "related", from: "CC-11", to: "CC-50"},
    {id: "00000000-0000-4000-8000-000000000006", type: "blocks", from: "CC-60", to: "CC-11"},
    {id: "00000000-0000-4000-8000-000000000007", type: "blocks", from: "CC-70", to: "CC-11"},
    {id: "00000000-0000-4000-8000-000000000008", type: "blocks", from: "CC-40", to: "CC-12"}];
  def relation($r): {id: $r.id, type: $r.type, issue: issues[$r.from], relatedIssue: issues[$r.to]};
  .query as $q | (.variables // {}) as $v
  | if ($q | contains("issueRelationDelete")) then {data: {issueRelationDelete: {success: true}}}
    elif ($q | contains("RelationBlocker")) and $v.id == "00000000-0000-4000-8000-000000000006" then
      {errors: [{message: "relation read failed"}]}
    elif ($q | contains("RelationBlocker")) then
      {data: {issueRelation: (rels[] | select(.id == $v.id) | relation(.))}}
    elif ($q | contains("GetRelations")) then
      ($v.id | ltrimstr("uuid-")) as $i
      | {data: {issue: {id: $v.id,
          relations: page([rels[] | select(.from == $i) | relation(.)]),
          inverseRelations: page([rels[] | select(.to == $i) | relation(.)])}}}
    elif ($q | contains("GetIssue")) then {data: {issue: {id: ("uuid-" + $v.id)}}}
    else {errors: [{message: "unexpected fixture query"}]} end' <<<"$payload"
printf '%s' '___HTTP_CODE___200'
SH
chmod +x "$TMP_ROOT/bin/curl"

SECTION='section="linear SKILL.md § Blocked Label vs Issue Relations"'

# label|args|rc|deleted relation (- for none)|stderr (- for none, * unchecked)
ROWS='
a Done blocker named by --blocked-by is refused|CC-11 --blocked-by CC-10|1|-|linear: refused=completed-blocker blocker=CC-10 state=Done SECTION
a Canceled blocker named by --blocks is refused|CC-20 --blocks CC-11|1|-|linear: refused=completed-blocker blocker=CC-20 state=Canceled SECTION
a Done blocker named by relation UUID is refused|00000000-0000-4000-8000-000000000001|1|-|linear: refused=completed-blocker blocker=CC-10 state=Done SECTION
an open blocker is removed|CC-11 --blocked-by CC-30|0|00000000-0000-4000-8000-000000000003|-
a Done blocker that crosses bundles is refused without the structural-repair flag|CC-11 --blocked-by CC-40|1|-|linear: refused=completed-blocker blocker=CC-40 state=Done SECTION
a Done blocker that crosses bundles is refused by relation UUID without the structural-repair flag|00000000-0000-4000-8000-000000000004|1|-|linear: refused=completed-blocker blocker=CC-40 state=Done SECTION
the structural repair removes a Done blocker that crosses bundles|CC-11 --blocked-by CC-40 --peer-rule-violation|0|00000000-0000-4000-8000-000000000004|-
the structural repair by relation UUID removes a Done blocker that crosses bundles|00000000-0000-4000-8000-000000000004 --peer-rule-violation|0|00000000-0000-4000-8000-000000000004|-
the structural repair keeps a leaf cross-bundle wait|CC-12 --blocked-by CC-40 --peer-rule-violation|1|-|linear: refused=completed-blocker blocker=CC-40 state=Done SECTION
the structural repair by relation UUID keeps a leaf cross-bundle wait|00000000-0000-4000-8000-000000000008 --peer-rule-violation|1|-|linear: refused=completed-blocker blocker=CC-40 state=Done SECTION
a Done peer blocker whose status name holds PIPE is refused with the structural-repair flag|CC-11 --blocked-by CC-70 --peer-rule-violation|1|-|linear: refused=completed-blocker blocker=CC-70 state=Done PIPE shipped SECTION
a failed relation read deletes nothing|CC-11 --blocked-by CC-60|1|-|*
the structural repair is refused for a peer pair|CC-11 --blocked-by CC-10 --peer-rule-violation|1|-|linear: refused=completed-blocker blocker=CC-10 state=Done SECTION
a related relation is removed|CC-11 --related CC-50|0|00000000-0000-4000-8000-000000000005|-
'

while IFS='|' read -r label args want_rc want_deleted want_err; do
  [ -n "$label" ] || continue
  want_err=${want_err//SECTION/$SECTION}
  want_err=${want_err//PIPE/|}
  label=${label//PIPE/|}
  [ "$want_err" != - ] || want_err=""
  : >"$TMP_ROOT/curl.jsonl"
  rc=0
  # shellcheck disable=SC2086 # args is a word list from the table
  (cd -- "$TMP_ROOT" && env -i HOME="$TMP_ROOT" PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=stub LINEAR_TEAM=CC CURL_LOG="$TMP_ROOT/curl.jsonl" \
    "$BASH" .agents/skills/linear/scripts/linear.sh issues remove-relation $args) \
    >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || rc=$?
  deleted=$(jq -r 'select(.query | contains("issueRelationDelete")) | .variables.id' "$TMP_ROOT/curl.jsonl" | paste -sd, -)
  assert_eq "$label: exit status" "$rc" "$want_rc"
  assert_eq "$label: deleted relation" "${deleted:--}" "$want_deleted"
  [ "$want_err" = "*" ] || assert_eq "$label: stderr" "$(cat "$TMP_ROOT/err")" "$want_err"
done <<<"$ROWS"
