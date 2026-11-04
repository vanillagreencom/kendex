# Reconcile tasks

Run for an incoming request, reply, worker result or blocker change, and during Start, the existing progress checkpoint and succession. Run before launching work or waiting. Use the current tracker as the work store under [Homes](../references/long-session.md#homes); the handoff indexes work and does not replace discovery.

## 1. Read the scope

Confirm tracker access and the consumer's selected task project under Homes. For Linear, use its installed `patterns/workflow-actions.md` sections Task discovery and Task-scope automation. Keep the consumer's team, project, identity, schedule and authority in its own instructions. An unavailable required read leaves reconciliation incomplete; retain its cause and next read on the affected item and hold dependent launches or closure.

At Start and the progress checkpoint, discover every open item in the selected project through every page. Include held work and checks selected under Homes. Compare this discovery with tracker ids in the handoff, incoming exchanges and linked work. Read a referenced item even when it is absent from the open list. During initial adoption or a scope change, also inspect terminal and archived items for unresolved outcomes before relying on open-item discovery.

For another event, start with its linked item and any affected dependencies. If it has no binding, search by the original request identity and requested outcome before creating an item. Search retained decisions and relevant memory through the [home contract](../references/home-contract.md#read-a-note). Read each candidate's current description and complete comments. Include terminal or archived matches when checking for prior work. A matching title alone establishes no binding. Resolve ambiguous candidates before creating or launching work.

## 2. Bind the request

Reuse the item that retains the same requested outcome. Record the incoming request's source, full message or request id, recorded time and a retrievable reference to its original content. Preserve the original request when a later message changes the outcome. Add the later message and its authorized decision to the same item. Distinct requested outcomes can have distinct items; a reply, attempt or delivery does not itself require another item.

When no item retains the outcome, create one in the selected project through the tracker's existing creation route. Put the original request reference, outcome, acceptance check and acceptance owner in its description. Follow the installed Linear skill's Issue Creation Routing when using Linear. An exchange that owes only a reply can end with that checked reply; retain any further requested result as work on the item.

Read back the binding before delegation or waiting. Preserve the request identity and outcome on that item through every next step. If capture or readback fails, hold the dependent action and keep the original request in its exchange home until capture succeeds.

## 3. Reconcile decisions and attempts

Read the item's latest comments, linked decisions and relevant exchanges, including tracker-only decisions with no mailbox ask. Apply the authorized current decision under [Authority](../references/decisions.md#authority). Preserve superseded decisions as history. Resolve a linked answered ask through [Answer an ask](../references/agent-reach.md#answer-an-ask) in the same step that records the answer and resulting next action on the item. An unresolved answer application remains work even when delivery succeeded.

Before launching anything, inspect existing attempts and available results for this request and outcome. Use the item's attempt references, the handoff's Sub-agents entries and the existing execution owner's records. For a Jarvis task id, use [Task command](session.md#task-command), including `task status --home HOME --id ID`, and read its retained task file and result file. For repository work, read the existing orch lane through its owning interface. Adopt a matching running attempt or reuse a completed result that meets the current request. Keep attempt identity at that owner and link it from the tracker item; create no second attempt registry. If a known launch or result has unread identity or state, retain that uncertainty and recover it before launching a replacement.

For an authorized new attempt, put the tracker item id, original request reference, current outcome and acceptance check/owner in its existing task brief. Record the returned attempt id and result destination on that same tracker item immediately. An unconfirmed launch remains a recovery action at the execution owner before any retry.

## 4. Check the outcome

Compare available evidence with the item's acceptance check under [Acceptance](../references/verification.md#acceptance). A worker's success, delivered message, merged dependency or answered ask proves only that event. None independently closes an unmet outcome. Use the existing acceptance and tracker completion owners for state changes; this procedure adds no completion disposition.

For terminal or archived items found during adoption, read their completion evidence, later decisions and any native closure history. Retain each unmet outcome on a current item before removing its recovery reference. Reopen the original through the tracker's supported route when authorized, or link an authorized surviving item that retains the original request and every unmet criterion. Read back that destination. An unavailable restoration or disposition remains unresolved; a terminal state alone proves no accepted result.

## 5. Retain the next action

On the same tracker item, record the current decision, evidence or explicit unknown, existing attempt reference, unresolved next action and responsible actor. For an external wait, retain its condition, evidence source and trigger or review date. For an answer or result awaiting acceptance, retain the acceptance action. Preserve the original criterion when another owner's item completes. Update only changed facts; write no periodic timestamp comment to keep work open.

Read back changed items and any surviving-item links before waiting or handing over. Use the [Handoff contract](../references/long-session.md#handoff) for the compact tracker ids and session state. At succession, reconcile every retained open item and next action with the current tracker before replacement. Reports consume these reconciled items; they do not create a separate selection policy. Continue authorized next actions, or wait through the existing event source when none can proceed.
