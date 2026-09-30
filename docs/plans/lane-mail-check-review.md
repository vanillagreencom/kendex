# Lane mail hook design review

Split the hook by concern into an invocation controller and an overseer policy library, while keeping the existing owners of mail, context records, launch records, and session rows.

## Framing

- **Goal**: reduce the size and review scope of the hook without changing which session receives mail or which condition holds a turn end.
- **Perspective**: a source and state-ownership audit after the facts-only idle judge landed.
- **Contract**: the live KEN-2130 Requirements and workflow `tmp/KEN-2130-planner-workflow.md`.
- **Constraints read**: `hooks/AGENTS.md`, `skills/AGENTS.md`, code-quality §§ Structure, Over-Engineering, Tests and Prove Your Guards, docs-writing, and the engine and harness architecture topics.
- **Assumptions**: none about runtime results. This review does not run a build, suite, validation runner, or harness probe.
- **Owner Bar dependency**: `tmp/owner-bar-KEN-2130.md` contains the parent's answer that `owner.md` is on the owner machine and is unavailable to this lane. It contains no Bar text. The parent authorizes a definite verdict against the accessible rules. The owner must assess this verdict against Bar. This report does not claim that assessment passed.
- **Output boundary**: only this report changes. The follow-ups below are proposals, not filed issues. The parent assigns report validation, commit, and the dev-return artifact to a generalist.

## Evidence boundary

Every current-source line range and byte count below belongs to revision `57ec19624490032529125a30e4cedc255933d1b6`. A later implementation must relocate by both range and semantic anchor. It must remeasure after rebasing.

- The checkout is clean before this report is written.
- KEN-2126 is Done in the live tracker. Its merge is `54326875969b8957a26e4225b0f1ec7ed9ed84fa`.
- KEN-2174 is included in the reviewed revision.
- Live KEN-2174 comment `c256f038-4b54-49ac-be88-f7334b144a2e` proposes splits of the hook, its renders, the watch, and the hook suite. This report answers that proposal below.
- File sizes come from `ls -ln`. Cut sizes come from read-only line scans with `LC_ALL=C`, including each line's newline byte. The partition of the hook suite sums to its measured 180202 bytes and 3329 lines.
- This is static evidence. It establishes the code's paths and proposed relocation sizes. It does not establish a live harness outcome or a failure rate.

### Size and ceiling

| File | Bytes | Bytes below 204800 |
| --- | ---: | ---: |
| `hooks/lane-mail-check.sh` | 193054 | 11746 |
| `.claude/hooks/lane-mail-check.sh` | 193054 | 11746 |
| `.codex/hooks/lane-mail-check.sh` | 193054 | 11746 |
| `.pi/kendex/hooks/lane-mail-check.sh` | 193054 | 11746 |
| `skills/orch/scripts/oversee-watch` | 195656 | 9144 |
| `.agents/skills/orch/scripts/oversee-watch` | 195656 | 9144 |
| `hooks/tests/lane-mail-check.test.sh` | 180202 | 24598 |
| `hooks/tests/lib/lane-mail-world.sh` | 27730 | Not near the ceiling |

The comment's sizes agree with this checkout. Its checker name does not. Commit-guards `scripts/byte-ceiling` sets `COMMIT_GUARDS_BYTE_CEILING_KB` to 200 by default. It measures tracked blob bytes. That gives 204800 bytes. Its `CHECKS.md` § byte-ceiling states the failure and warning rules. `tools/guard` names that checker separately from doc-limits. Doc-limits governs documents, not these Bash scripts. Its generated-file exclusion does not exempt these renders from byte-ceiling.

The next edit is not certain to fail. For these files, it fails the size check only if its resulting tracked blob exceeds 204800 bytes. A blob of exactly 204800 bytes passes with a near-ceiling warning. The impact is a blocked fix and a wider review if a split must be added to that fix. The condition is reachable because every change to these files reaches the commit chain. The source does not establish how many future fixes exceed the budget.

The hook's executable body starts after its frontmatter at line 12, byte offset 41619. Header size is a material part of this file. Moving function bodies does not remove the hook's declared contract. Do not cut the declaration to hide the size problem.

## What KEN-2126 removes and what remains

The merge diff removes these requirements from the implementation:

- Classify a question from a trailing question mark or a table of phrases.
- Read the final assistant text through `transcript_final_line` and `asks_the_person`.
- Derive a turn's start from transcript records through `transcript_turn_start`.
- Compare message timestamps against that derived start.
- Send the extracted question through `question_notice` and judge it through `question_turn_check`.
- Emit the removed `question-turn`, `question-notice`, `question-notice-unsent`, and `turn-start` keys.

These are removed mechanisms, not deleted obligations from KEN-2130. The unattended lane must still report through mail.

Current source retains these duties:

- Refuse named question tools, not text, through `question_tool_check` at lines 1301-1357.
- Judge idle from `lane-mail events`, a sent-count record, handoff state, the newest directive's halt flag, and launch-marker presence at lines 1358-1480.
- Persist the hold before refusing. On the continued turn, send a notice and count that notice as a send. Pi's continued response takes the notice path when another hook caused the continuation.
- Judge handoff before idle. A standing handoff exits before idle runs. Close-out removes the launch marker; it is not a separate done-record query inside `idle_check`.
- Read transcripts for usage and session identity, not lane message text. Those reads remain necessary for context marks and Copilot caller identity.
- Carry unattended instructions to the launchers for all harnesses. The merge changes `lib/lane-launch.sh`, `open-terminal`, and their renders. That obligation is outside this hook's state owner.

The current suite's lines 1325-1331 check the hook and its three renders for the deleted readers and a transcript text selector. Its idle rows include statements and questions under the same mail facts. Its `words-read` control at lines 2871-2881 plants a text-based judge. These are source assertions inspected here, not test results from this round. A grep pin alone does not prove the absence of every possible text reader.

## Events and delivery

An empty matcher applies the wrappers to all tools. Wrappers resolve the judge beside themselves and `exec` it through the running Bash. A missing judge produces a keyed stderr report at exit 0 in `lane-mail-start.sh`, `lane-mail-prompt.sh`, `session-start-row.sh`, `session-end-row.sh`, and `stop-failure-row.sh`. Those events continue. The halt and deliver wrappers instead issue a keyed refusal at exit 2. The compact wrapper exits 2 with an operator warning, but cannot hold compaction. They do not own a second judge.

| Harness event or producer | Entry point and arm | Actual reach and work |
| --- | --- | --- |
| `Stop` | `lane-mail-check.sh`, default `stop` | Claude Code and Codex register Stop. Copilot registers `agentStop`. Pi maps it to `turn_end`, dispatched at `agent_before_settle`. Delivers mail, then judges handoff, then idle. Pi lane rows run before delivery can exit. |
| `PostToolUse` | `lane-mail-deliver.sh` to `deliver` | Claude Code and Codex use PostToolUse. Copilot uses `postToolUse`. Pi uses `tool_result`. A lead receives mail as context. A named overseer also receives its context mark or a judgement gap. |
| `PreToolUse` | `lane-mail-halt.sh` to `halt` | Claude Code and Codex use PreToolUse. Copilot uses `preToolUse`. Pi uses `tool_call`. Reads a lane halt and refuses question tools after the halt check. Writes the first Pi lane tool row of a turn. |
| `SessionStart` | `lane-mail-start.sh` to `start` | Copilot-only wrapper, registered as `sessionStart`. Records the lead and prunes old lead and pending records. Delivers mail as context. |
| `UserPromptSubmit` | `lane-mail-prompt.sh` to `prompt` | Copilot-only wrapper, registered as `userPromptSubmitted`. Delivers lead mail as context. It does not record a lead merely from a prompt. |
| `SessionStart` | `session-start-row.sh` to `row` | Runs on Claude Code, Codex, and Pi where the event exists. Records a top-level non-lane session's start through the session-row owner. It does not deliver mail or judge marks. |
| `SessionEnd` | `session-end-row.sh` to `row` | Executable on Claude Code. Records the non-lane session's end. Codex, Pi, and Copilot do not receive this wrapper. |
| `StopFailure` | `stop-failure-row.sh` to `row` | Executable on Claude Code. Records the failure, including usage-limit and prompt-too-long facts used by the watch. |
| `PreCompact` | `lane-mail-compact.sh` to `compact` | Copilot-only wrapper, registered as `preCompact`. Flags automatic compaction for a recorded lead lane or named overseer. Manual compaction flags nothing. This event cannot hold compaction. |
| Copilot `session.usage_info` | `scripts/copilot-lane-context/extension.mjs` to `usage` | The extension excludes events with `agentId`. It supplies session, cwd, current tokens, and token limit. The hook writes the lead's context record. This is not a configured harness hook event. |
| Pi mailbox file wake | `pi-hooks/extensions/lane-mail-wake.ts` through the registered deliver hook | Uses `deliver` without a real tool or `context_window`. It can deliver mail. The Pi overseer tool judge skips context reading and record replacement for this payload. |

OpenCode and Cursor appear in frontmatter but receive advisory instructions and rules. They do not execute this Bash through these events. Cursor has no global hook target. Gemini is excluded from the judge because it has no Stop counterpart. Antigravity is excluded because its Stop payload lacks `stop_hook_active`. Do not report frontmatter membership as executable delivery.

The reviewed install registers the judge, halt, and deliver hooks in `.claude/settings.json`, `.codex/hooks.json`, and `.pi/kendex/hooks.json`. Other wrappers can reach the judge when installed. Their catalog declarations are not proof that this worktree registers them.

Delivery authorities are `crates/core/src/hook/delivery.rs::delivery`, `hook.rs::codex_event`, `harness/caps.rs::pi_listener`, and `harness/copilot/mod.rs::event`. Placement and command construction belong to `engine/targets.rs::hook_target`, `pi_hook`, and `copilot_hook`. Rendering a script-backed hook in `engine/desired_kinds.rs::hook_artifact` places its script bytes and registry edits. It does not copy a sibling library tree from `hooks/`.

## Concern inventory

Ranges in this table refer to `hooks/lane-mail-check.sh`. Writes include effects delegated to another script. Memory writes end with the invocation unless the table names a file.

| Concern and anchors | Actual reads | Actual writes | Coupling |
| --- | --- | --- | --- |
| Output contract, lines 174-583 and 1281-1300: `message`, `json_string`, `refuse`, `hand_over`, `tool_notice_told` | Arm, harness, role, failure cause, unread envelopes, instructions, pending tool notice | stderr, harness JSON on stdout, then the mail acknowledgement; `context-told` only after output carrying the gap succeeds | Every concern uses this transport. A deliver refusal carries the tool mark before the mailbox reason. Keep this writer singular. |
| Payload and event validation, lines 584-680 | argv, stdin JSON, tool name, retry flag, agent fields, session, transcript, Pi window, Copilot trigger and usage cwd | Parsed invocation fields; early keyed refusal or cross-harness skip | Caller and retry state control all later work. A bad payload refuses even on a continued Stop. |
| Copilot lead identity, lines 681-779: `record_lead`, `copilot_lead_file` | Event, session id, transcript directory, lead record existence | Empty lead files, refreshed modification times, removal of old lead and pending files | An unknown caller gets no mail, no halt-clear command, no compaction flag, and no usage record. Lead and subagent context must not be mixed. |
| Retry and caller policy, lines 781-830: `stall` and early exits | `stop_hook_active`, arm, caller | Report or refusal; no durable state | Continued Stop skips mailbox delivery. Clearable handoff marks still repeat. Idle has its own persisted hold. |
| Root, item, launch and install trust, lines 838-1092: `read_marker`, `read_branch`, `lane_launched`, `resolve_reader`, `call_runs` | Project dir or usage cwd, git root and common dir, branch, launch marker, mailbox directories, installed reader candidates, exact shell command | Cached root/item/launch and script paths; a recovery command in memory | All lane duties use this identity. The hook never executes the open repo's reader unless installed in that repo. A missing marked mailbox can refuse calls until its mkdir remedy runs. |
| Mail delivery and halt, lines 1093-1280: `mail_check`, `watch_live`, `acknowledge` | `to-lane.jsonl` through `lane-mail inbox --peek`, count header and envelopes, fleet state, watch pid record and process liveness | Context or refusal; `lane-mail inbox --ack` moves `to-lane.cursor` after output. Halt arm moves no cursor | Mail reader owns the cursor and halt clamp. Named overseer and live watch share that cursor, so only the active reader may consume it. |
| Question-tool policy, lines 1301-1357 | Tool name, launch answer, caller, installed ask route | Refusal and route in output only | Runs after halt. Ordinary unread mail must return, not exit, from the halt branch or it bypasses this check. |
| Facts-only idle policy, lines 1358-1480: `record_sent`, `idle_notice`, `idle_check` | Lane-mail events, outbound asks/notices, newest inbound directive's halt flag, `sent-count`, role and retry state; earlier handoff exit | Atomic replacement of `sent-count`; an outbound notice through lane-mail; idle refusal | Its notice changes the count it judges. The hold and the count form one owner. Handoff and mail can end the invocation before idle. |
| Handoff record and remedy, lines 1532-1699 and 2505-2661 | `workflow-state handoff-standing`, record's session or pane owner, state existence, branch, installed scripts | Handoff instructions in output; no handoff record | The lane or overseer writes its own handoff. The hook only reads it. A standing lane record, or this overseer's own record, exits before mark reads. |
| Common context reading and judgement, lines 1700-1965 | Effective context setting, installed `lane-context.sh`, bounded transcript tail and full fallback, adapter reading, Copilot extension record and statusLine fallback, compaction flag and pending marker | `context.json` through `lane_context_record` when a reading is taken; mark output and gap reports | Lane and overseer use one arithmetic judge. Missing capacity is not zero room. Account judgement remains separate from an unread context figure. |
| Context producer arms, lines 1981-2104: `session_gate`, `gated_box`, `compaction_mark`, `usage_read` | Launch or overseer identity, installed context library, usage payload or auto trigger | `compaction.json`; Copilot `context.json`; removal of stale context if a newer usage write fails | The usage extension owns pending markers. Stop waits on them. Compaction flag remains independent of later usage writes. |
| Overseer identity and repair, lines 2144-2271: `overseer_identified`, `overseer_identify`, `overseer_heal` | tmux server/pane and start, fleet `.overseer`, installed harness, caller launch home through the existing libraries | Cached identity and launch home; missing server start, harness and home through `ol_record_heal` and `workflow-state update` | Mailbox selection, session gate and tool policy share this answer. A read heals at most once per invocation. This is not an independent marks-only unit. |
| Overseer turn-end marks and lost identity, lines 2106-2143 and 2272-2430 | Bound transcript, context reading, earlier context record for a lost pane, `oversee-succeed --check-marks` key and fields, succession setting from that answer | Overseer directory, context reading or null-token gap record; turn-end refusal or report | The hook delegates account triggers to succession's judge. A lost record gets `pane-unrecorded` only if the stored context names this pane. It is not treated as the current overseer. |
| Overseer tool-call context, lines 2663-2791 | Cached identity, own context, context setting, own standing handoff when there is a notice, last told session/key | `context.json` or gap, `TOOL_NOTICE`, pending told line; remove `context-told` on a clean check | Subshell role/item changes must not affect later mailbox selection. Reached mark repeats; a standing gap is delivered once per session and first key. No account request runs per tool call. |
| Session facts, lines 2431-2460 and 2792-2824: `session_row`, `lane_row` | Payload event, top-level session/process facts through session-rows, tmux identity, Pi lane transcript Stop reason | Locked append to overseer `session-<server>-<pane>.jsonl` or Pi lane `session-rows.jsonl` | Row arm can run before fleet identity exists. Pi lane rows precede mailbox exit. An overseer Stop row runs after the handoff-record escape, before its context read. |
| Lane account mark, lines 2461-2503 and the lane branch of `handoff_check` | Harness or Pi provider, own credential directory, effective headroom setting, bounded `lanes pick --lane` response | Account refusal or keyed unlisted, timeout, or unmeasured report | Reuses lane-launch's provider decision. Does not infer account room from transcript absence. The account and context marks share one handoff escape. |

## State ownership and lifetime

### Existing durable owners

| State | Owner and writers | Lifetime and consumers |
| --- | --- | --- |
| Launch marker under the common git directory's `lane-mail/` | Lane launch/close path. Hook reads only | Binds a root to a launched item. Close-out removes it. A committed mailbox cannot substitute for it. |
| Mail files and `to-lane.cursor` | `lane-mail`; append/lock helpers own line writes and locking | Mailbox lifetime. Hook, workflow inbox reads, and watch use the same reader. A halt survives `--ack`; a plain lead inbox read clears it. |
| Lane `sent-count` | `record_sent` and `idle_check` in this hook | Lane mailbox lifetime, not one turn. Atomic rename replaces count and hold together. Schema Recording policy gives it the lane status file's retention. |
| `context.json` | Format, path and atomic write in `lib/lane-context.sh`; hook producers supply readings or gaps | Lane reading follows mailbox retention and launch identity rules. Overseer reading is overwritten and not pruned. `lanes context`, succession and watch consume it for their stated questions. |
| `compaction.json` | `lane_context_compaction_flag` and its one reader | A session-specific backstop in the mailbox. A later usage reading does not clear it. A predecessor's session does not mark its replacement. |
| `context-told` | Tool policy selects session/key; `refuse` or `hand_over` commits it | Lives beyond a hook invocation. A clean tool check removes it. A changed session/key permits another notice. Only named or positively recognized lost overseer paths touch it. |
| Copilot lead files | `record_lead` | User cache, outside the repo. SessionStart and proved lead Stop refresh them. SessionStart removes files untouched for 30 days. |
| Copilot pending files | Copilot usage extension; hook reads and prunes old files | Extension sets a marker before dispatch. Only a successful newest reading removes it. Hook waits 25 polls of 0.2 seconds, then reports unmeasured. |
| Overseer session rows | `lib/session-rows.sh`, through `file-lock.sh` and `mailbox-append.sh` | Shared pane-key file, with SessionStart separating harness sessions. Watch reads the fleet-record path. Rows are not ordinary outbound mail. D010 fixes that boundary. |
| Pi lane session rows | `session_rows_lane_write` | Lane mailbox lifetime. Stop and first PreToolUse give watch and `lanes state` facts without reading the pane. The schema states no separate pruning. |
| Fleet `.overseer` and handoff record | `workflow-state` writes; `overseer-launch.sh` owns identity definitions and repair; launch, register, watch start and succession supply facts | Fleet lifetime. Successors replace launch identity. Hook reads handoff and repairs missing identity facts; it does not own fleet teardown. |
| Repeat-watch pid/argv records | `lib/watch-pid.sh` and repeat watch acquisition/cleanup | Live watch lifetime. The hook probes this owner to decide who reads overseer mail. Single passes leave no live-watch record. |
| Watch observation baseline | `pr-watch` state through `lane_row_commit` and `mail_row_commit` | Outlives a watch pass and process. Overseer dead/walled counts, mark repeats, and context-gap told/alerted rows share the existing baseline. |

### Invocation and pass owners

- The hook owns parsed payload, root/item, caller, retry state, trusted script paths, scratch directory and EXIT cleanup for one invocation.
- `IDENTIFIED` caches a shared role answer. `ROLE` and `ITEM` are shared inputs, not properties a sourced file may reset.
- `TOKENS`, `WINDOW`, `MODEL`, `READ_GAP`, `MARK` and failure fields carry a reading or report across the call chain. They are not durable records.
- `ACK_LINES`, `TOOL_NOTICE` and `TOLD_PENDING` belong to the output transaction. They must not commit before the model output is written.
- The tool judge's subshell changes role and item without changing the following mailbox check's role and item.
- The watch owns its process, scratch directory, long-pass child, mail passes, baseline commits and final exit. `LONG_RETURNS` transfers named results from the child. Each long pass resets the account-mark memo.
- `overseer_down` runs before mail reads. It uses the same pane and account judgement as `check_overseer`, but retains its own interval-bound wall memo. These are phases of the watch owner, not two independent watches.

A sourced file changes code placement. It does not separate any of these lifetimes. The proposed libraries below stay inside these owners. They must name their allowed inputs and outputs and must not acquire another cursor, context format, fleet record, scratch trap, or baseline store.

## Verdict and approach

### Split by concern

Use a concern split for the overseer policy, the watch's overseer checks, and the test cases. Keep one configured hook entry and its existing event wrappers.

- The overseer policy runs without a lane item and has its own session-bound handoff and notification rules. It now has both Stop and deliver consumers. Its test cases already have distinct lane and overseer worlds.
- Mailbox delivery already delegates durable ownership to lane-mail. Context and session-row ownership already live in libraries. Creating new owners for them would duplicate a decision.
- Root, caller, retry, trust, role identity and output commit order are shared across concerns. Keep them in the controller.
- Keep `overseer_identified`, `overseer_identify`, and `overseer_heal` in the controller. Both mailbox selection and marks need their answer. Moving only those names to an overseer marks file would hide that shared dependency.
- Move overseer context/mark policy and tool policy together. Do not create one library per function or split read, record, judge and notification into separate owners.
- Move the watch's overseer checks as one cohesive unit, including its mail-pass gate. Do not create separate mark, wedge, wall and recovery owners. They share a session reading, mark memo and committed baseline.

Under code-quality § Over-Engineering, these cuts add no speculative consumer, registry, plugin interface, new process, or second arithmetic judge. The new libraries exist for current branches and current byte pressure. The accepted cost is an installed library dependency and test-fixture updates. There is no claim that fewer source bytes reduce runtime latency.

Under code-quality § Structure, the controller and watch keep their resource lifetime. The durable owners above remain unchanged. An extraction that leaves unnamed global dependencies or adds a second file writer does not satisfy this verdict.

### Alternatives

| Alternative | Decision and reason |
| --- | --- |
| Keep every file unchanged | Reject. The watch has 9144 bytes left and the hook has 11746. The main suite combines several tested functions in 180202 bytes. A source split can be planned before an unrelated fix reaches the ceiling. |
| Register separate mail, lane-mark, overseer-mark and row hooks | Reject. Event ordering would become an installation property. It would split one acknowledgement/output transaction and repeat root and role discovery. No requirement asks for that behavior change. |
| Add `hooks/lib/` files and source them beside the hook | Reject for this cut. Current script-backed hook installation writes the declared script, not a sibling tree. Use the existing installed orch scripts tree. |
| Move all Bash functions unchanged into arbitrary sourced files | Reject as a design claim. That changes packaging only. Use the named concern unit and retain the explicit shared owner and call order. |
| Raise the ceiling or exempt renders | Reject. Neither reduces coupling or the main suite's combined test scope. |
| Split mailbox, idle, lane marks, and session rows into further production units now | Defer. Mail, context and row owners already exist. Keep the facts-only lane policy together until a concrete change needs a further cut. The overseer extraction alone creates measured room. |

## Ordered cut proposals

These are technical follow-up proposals. They are not tracker items. P1 must land before the suite cuts. P2 through P6 have no dependency on each other after P1. P7 follows those suite cuts so its controls can move with its code. P8 needs P1's fixture support for library mutations but does not need the hook extraction.

### Budgets

Relocated bytes are not new behavior. The measured cut is deleted from its donor and added to its receiver. Changed interfaces, load checks, notices, setup and controls are new or rewritten code and must be reported separately.

- P1 relocates 251 lines and 11219 bytes, including helper bodies and shared setup. Limit new fixture integration to 53 lines and 2775 bytes. That allowance is the measured size of the existing hook context-loader block at lines 1729-1781, not an estimate of implemented code.
- Each suite-only cut gets at most 18 new lines and 864 bytes for its own header, import and result footer. This comes from the measured original lines 1-16, 797 bytes, and lines 3328-3329, 67 bytes. Move existing case setup with its rows rather than recreate it under this budget.
- P7 and P8 each get at most 53 new or rewritten production integration lines and 2775 bytes, across controller and new library together. Do not charge relocated body lines to that allowance.
- New error/load controls for a production cut get a separate ceiling of 251 lines and 11219 bytes across affected suites and fixtures, based on P1's measured helper cut. Keep each resulting suite below 65536 bytes. This is a proposal budget, not a measured test addition.
- If an implementer cannot fit a correct interface or control within these budgets, return the measured difference for review. Do not raise the file ceiling or hide additions as relocation.

### P1: move test helpers before moving cases

**Proposal**: move the main suite's helper definitions and neutral shared setup into `hooks/tests/lib/lane-mail-world.sh`.

**Source cut lines and anchors**:

| Main-suite range | Semantic anchor |
| --- | --- |
| 73-92; 100-109; 240-244 | `killed_stop`, `unlaunched`, `global_home` |
| 287-292; 302-305; 309-315 | `new_handoff_lane`, `template_fields`, `record_handoff` |
| 518-520; 553-556; 645-652; 672; 810-815 | `filler`, `account_env`, `stop_pi`, `asked`, `old_dispatcher` |
| 981-987; 989-992; 994-1000; 1001-1006 | `new_pi_lane`, `pi_rows`, `pi_tool`, `pi_stop` |
| 1076-1078; 1079-1082; 1085-1087; 1325-1328 | `sent_record`, `notices`, `read_mail`, `text_reads` |
| 1346-1349; 1354-1355; 1450-1455; 1502 | `stop_unnamed`, `overseer_route`, `overseer_record_named`, `owned_payload`, `gap_record` |
| 1522-1532; 1595-1630; 1689-1700; 1906-1911; 1939-1951 | `lost_identity`, `overseer_gap_word`, `gap_unwritten`, `unrecorded_rows`, `state_unread` |
| 2082-2088; 2967-2971; 2977-2981; 3047-3050 | `tool`, `named_session`, `new_plain_session`, `bound_session` |
| 3089-3096; 3097-3100; 3103-3111 | `start_watch`, `stop_watch`, `hole_watch_library` |
| 273; 299; 317; 547; 993; 2081 | `MUTANT_PATH`, `HANDOFF_FIELDS`, `TRANSCRIPT`, lanes-fixture import, `PI_TURN`, default `TOOL_NAME` |

**Intent and reason**:

- Preserve the world's one temp root, assertions and EXIT trap. A new suite must not source the old suite to get its helper functions.
- Definitions create no scenario on import. Keep account setup at lines 548-552 with account cases. Keep fault setup such as `FAIL_MV_BIN` and `NOT_JSON` private to the cases that use it.
- Place the shared setup after the world has defined `TMP_ROOT` and `REPO_ROOT`. Keep Bash 3.2 compatibility.
- Make existing variant/mutant and isolated-install helpers able to plant a mutated library in the copied orch install. Resolve and copy the runtime file; never edit the repository library through a fixture symlink. No test-only override enters production code.

**Expected delta**: delete 251 lines/11219 bytes from the suite and relocate them to the world. The suite becomes 168983 bytes before new integration. The world becomes 38949 bytes before new integration, at most 41724 under the proposed allowance. Add fixture checks for the copied-library path separately. No production behavior changes.

**Validation**: run the main suite and all existing lane-mail suites that source this world in separate processes. Assert unchanged fixture isolation, keyed results and controls. Run one control against a copied library and prove that the real source and the fixture's unmodified sibling remain unchanged. The parent, not this report round, runs these checks.

### P2: isolate the overseer's Stop cases

**Proposal**: create `hooks/tests/lane-mail-check-overseer-stop.test.sh`.

- **Cut**: main-suite lines 1333-2028, from `the overseer's own turn end` through the qualifying-headroom control; and 2667-2747, from `owned-empty-path` through `overseer-fields`. Exclude P1's moved helpers.
- **Intent**: keep mark-key handling, transcript binding, healing, lost records, succession-off behavior and own-handoff controls together.
- **Expected delta**: gross source blocks are 777 lines/47219 bytes. After P1, relocate 686 lines/42541 bytes. New suite maximum is 43405 bytes under the suite bootstrap allowance. Delete the same relocated case bytes from the main suite. Add no new mark policy.
- **Dependency**: P1.
- **Validation**: run this suite alone and its existing overseer-tool sibling. The own-record, different-pane, server-start, unowned-transcript, missing-figure and succession controls must still reach their own rules. A passed marks suite cannot substitute for a mailbox suite.

### P3: isolate lane handoff cases

**Proposal**: create `hooks/tests/lane-mail-check-handoff.test.sh`.

- **Cut**: lines 275-973, from `the handoff marks` to before `a Pi lane's turn rows`; and 2522-2666, from `Each handoff mark's refusal` to before the empty-path overseer control. Exclude P1's moved helpers and setup.
- **Intent**: keep context/account marks, adapter readings, safe-point remedy, account fixtures, bounded-tail fallback, library-load gaps and record-escape controls together.
- **Expected delta**: gross blocks are 844 lines/47818 bytes. After P1, relocate 802 lines/45847 bytes. New suite maximum is 46711 bytes. The existing account setup and window mutant move with the cases. No new context arithmetic.
- **Dependency**: P1.
- **Validation**: run the new suite alone. Verify both sides of context and account boundaries, standing handoff before dependency failures, relocated harness roots, and the tail/full-file controls. Keep explicit fake account environment and offline fetch fixtures.

### P4: isolate the facts-only idle cases

**Proposal**: create `hooks/tests/lane-mail-check-idle.test.sh`.

- **Cut**: lines 1064-1332, from `the idle judge at a turn end` to before the overseer's Stop cases; and 2801-2954, from `no-idle-refusal` through `idle-halt-keeps-hold`. Exclude P1's moved helpers.
- **Intent**: preserve the count, held continuation, notice self-count, latest halt, no-text-read pin and Pi continued-response controls as one function's tests.
- **Expected delta**: gross blocks are 423 lines/22205 bytes. After P1, relocate 409 lines/21619 bytes. New suite maximum is 22483 bytes. Keep `NOT_JSON` and the planted word reader in this suite's private cases. No restored text classifier.
- **Dependency**: P1.
- **Validation**: run the new suite alone. Controls must prove the outbound box filter, hold recording before refusal, continuation cap and no-text behavior. Verify that an idle notice does not count as a user report on the next comparison. Keep the render absence check in this suite.

### P5: isolate overseer mailbox cases

**Proposal**: create `hooks/tests/lane-mail-check-overseer-mail.test.sh`.

- **Cut**: lines 2955-3296, from `the checkout's overseer mailbox` to before `deliver-no-ack`. Exclude P1's moved helpers.
- **Intent**: keep peer mail, named session, alternate pane, server-start binding, live-watch ownership and failed state/library controls together.
- **Expected delta**: relocate 307 lines/15516 bytes after P1 from a gross 342-line/16597-byte block. New suite maximum is 16380 bytes. `deliver-no-ack` stays in the lane-mail/controller suite because it proves the general delivery acknowledgement.
- **Dependency**: P1.
- **Validation**: run this suite alone. A live watch must keep its mail. A single-pass or absent watch must not leave it unread. Another session and a subagent must not consume it. A failed watch probe must not become an absent watch. Fixture cleanup must kill the fake watch.

### P6: isolate Pi lane row cases

**Proposal**: create `hooks/tests/lane-mail-check-pi-rows.test.sh`.

- **Cut**: lines 974-1063, from `a Pi lane's turn rows` to before idle; and 3307-3327, from `no-lane-row` through the moved-Pi-root control. Exclude P1's moved helpers and `PI_TURN` setup.
- **Intent**: keep the hook's Pi row writer tests separate from context and mail. The row reader remains tested by its own orch suites.
- **Expected delta**: gross blocks are 111 lines/5654 bytes. After P1, relocate 86 lines/4698 bytes. New suite maximum is 5562 bytes.
- **Dependency**: P1.
- **Validation**: run the new suite alone. Verify Stop, first PreToolUse, subagent exclusion and moved-root controls. Also run `hooks/tests/session-rows.test.sh` and orch's Pi lane reader suites for integration, without copying their reader tests into this suite.

After P1-P6, the existing main suite retains 788 lines/38762 bytes before editorial bootstrap changes. Its budgeted maximum is 39626 bytes. It retains payload, root, install trust, lane mailbox, halt, question-tool, general delivery, and ordinary-session silence cases. No test runner should source it as a helper.

The existing Copilot suite is 71191 bytes. It also exceeds code-quality's approximate 64 KB test guideline. This report does not claim that the main-suite cuts fix that separate suite. Its cases and local helper definitions remain unchanged by these cuts. A later concern audit must measure its own seams before prescribing a split.

### P7: extract the hook's overseer policy

**Proposal**: create `skills/orch/scripts/lib/lane-mail-overseer.sh`, with its tracked `.agents/skills/orch/scripts/lib/lane-mail-overseer.sh` render.

| Source range in the hook | Semantic anchor | Relocated lines | Relocated bytes |
| --- | --- | ---: | ---: |
| 1586-1611 | `handoff_is_mine`, overseer record ownership | 26 | 1550 |
| 2106-2143 | `overseer_box`, `overseer_transcript_owned` | 38 | 2035 |
| 2272-2430 | `overseer_gap_record`, `overseer_context_read`, `overseer_unrecorded`, `overseer_marks` | 159 | 7571 |
| 2663-2791 | `overseer_tool_check`, `overseer_tool_judge`, `overseer_tool_held` | 129 | 5909 |

**Intent and ownership**:

- Keep identity cache and healing at lines 2144-2271 in the controller. This answers the proposed `overseer_identified`/`overseer_heal` cut: these are shared session-selection functions, not marks-only functions.
- Move overseer reading, gap, mark-key handling and tool notification policy together. Retain existing function names during the relocation. Do not add forwarding wrappers or expose functions solely for tests.
- The new file is definition-only. It adds no EXIT trap, payload parse, root discovery, account reader, context arithmetic, or file format. Common invocation fields remain owned by the hook. The library's allowed effects are the existing overseer records and notices in the inventory.
- Keep `message`, `refuse`, `hand_over`, `tool_notice_told`, `resolve_reader`, `session_gate`, common context functions, `session_row`, and the final dispatch in the controller. Keep output commit state there. The library selects a notice; the controller commits delivery and acknowledgement.
- Load from the `SCRIPTS` path established by `resolve_reader`, never from cwd or a sibling `hooks/lib` path. Use the current interpreter's child parse/capability probe pattern before in-process sourcing. Add one cached load outcome, not a generic module loader.
- Load before the first overseer-policy use, including the own-record escape, compact/usage `gated_box`, and lost-overseer report. Do not call an undefined relocated function on the no-lane gate result. Preserve the existing positive identity checks before reporting an overseer-only dependency gap to an ordinary session.
- A missing or unreadable policy library must produce a keyed unjudged/install gap, not a silent below-mark answer. On deliver, hand the gap to the named session as context at exit 0. A turn-end install gap must leave an escape and cannot trap the session on an unavailable command. Keep the existing mailbox path operational through its retained identity owner.
- Preserve the tool judge's subshell, cached identify/heal answer and notice-before-mail order. If loading requires moving a call boundary, retain captured healing diagnostics in the same notice transaction.

**Expected delta**: relocate 352 lines/17065 bytes from each of the hook's source and three renders. Add the body once to the orch source library and once to its render. Before new glue, each hook copy becomes 175989 bytes. Under the production integration allowance, each remains at most 178764 bytes and the new policy file at most 19840 bytes. These are conservative per-file maxima, not cumulative use of the same allowance. New controls have the separate test budget above. Behavior, thresholds and registrations stay unchanged.

**Dependency**: P1-P6. The isolated-install fixture and mutant must follow the relocated production body rather than changing a now-absent string in the dispatcher.

**Validation**: run all lane-mail hook suites, session-row suite, and the hook install/dependency tests. Pin the old keyed status/JSON contracts. Add controls for missing and malformed policy libraries, output-before-told, ordinary-session silence, record ownership and tool/mail coexistence. Preserve controls for unread payload, missing reader, library parse failure under Bash 3.2, and Pi wake without a window. Validate local/global installs, relocated Codex/Pi roots, and Copilot's own scope. A hook source grep does not validate installed library delivery.

### P8: extract watch overseer checks as one unit

**Proposal**: create `skills/orch/scripts/lib/oversee-watch-overseer.sh`, with its tracked `.agents/skills/orch/scripts/lib/oversee-watch-overseer.sh` render.

| Source range in `oversee-watch` | Semantic anchor | Relocated lines | Relocated bytes |
| --- | --- | ---: | ---: |
| 2170-2323 | `OVERSEER_LINE`, note/publication and recovery notice functions | 154 | 8669 |
| 2353-3003 | `overseer_marks_judge` through `check_overseer` | 651 | 34206 |
| 3755-3796 | `OV_WALL_*`, `overseer_down` mail gate | 42 | 1867 |

**Intent and ownership**:

- Keep `bounded_account_read` and `BOUNDED_OUT` at lines 2324-2352 in the watch. Account roster and owed-work paths at lines 3335, 3557 and 3590 also consume them. Moving them into an overseer-only unit would create an incorrect dependency.
- Keep `lane_row_get/set/clear/commit`, baseline ownership, scratch cleanup, watch claim, child scheduling, `LONG_RETURNS`, pass clock, and final exit in the watch.
- The library owns the code for the existing overseer check chain, not another watch lifecycle. It reads the named session through existing launch/session-row/context owners. Its state fields belong to the current watch or current pass.
- Keep acquisition and repair in the existing `lib/watch-overseer-record.sh` and `lib/overseer-launch.sh`. Keep fleet-log publication's shared writer at its existing site. Source the definition-only new file after existing dependencies and before any overseer function is called.
- Preserve account memo reset at each `long_pass` and the interval-bound mail wall memo. Preserve `overseer_down` before mail reads and `check_overseer` before other long-pass consumers advance their baseline.
- Do not make separate wedge, account, death or recovery libraries. They share `OV_*`, `OVERSEER_MARK_*`, `OVERSEER_MARK_ROWS`, and the same committed rows. A sourced split alone does not separate those owners.

**Expected delta**: relocate 847 lines/44742 bytes from the watch source and render. Each watch copy becomes 150914 bytes before new glue, at most 153689 under the production allowance. The new library is at most 47517 bytes under that allowance. Keep new integration and controls separate from relocated bodies in the review delta.

**Dependency**: P1's safe copied-library mutation support. This cut can be implemented independently of P7.

**Validation**: use `skills/orch/tests/run-all.sh` with the existing `oversee_watch` selector, not a new runner. Include overseer, overseer rows, lifecycle, mail, accounts, owed work and Pi lane cases. Pin mark memo reset, bare-process/row/context verdicts, wall refutation, recovery attempts, no qualifying account, no launch line and owner gap escalation. Run controls against the new runtime library, not the old watch body. Verify that a stopped or succeeded overseer does not advance another consumer's baseline or drain its mail.

## Installation, tests and documentation

### Install and render changes required by production cuts

- Keep all existing hook names, events, harness declarations and `requires` edges. The judge requires halt and deliver; row wrappers require the judge without a reciprocal edge. A reciprocal edge to a Claude-only row wrapper would withhold the judge from other harnesses.
- `engine/deps.rs` and `desired_kinds.rs::not_written` decide whether companions are deliverable together. P7 adds an orch library, not a new catalog hook companion.
- Orch skill scripts carry their `lib/` subtree in skill installation. New production libraries join the source and `.agents` render in the same commit.
- Replay the hook change into its three tracked renders. Do not replace a rendered skill tree with source wholesale.
- Add new render paths to `.kendex-generated.json` in sorted order. Test files render nowhere. Leave `.kendex-lock.json` to main's lock-record process.
- Preserve the current reader capability checks and feature detection. Do not introduce a hard startup requirement for ordinary non-fleet sessions solely to support the new file.
- The install test must use kendex's installed orch tree and registered hook, not only a fixture symlink to the source scripts. No Rust installer change is expected for the proposed location.

### Suite entry and control requirements

- `.github/workflows/skill-tests.yml` discovers hook suites with `hooks/tests/*.sh`. A new executable suite at that level joins the existing hook shard. Shared helpers stay under `hooks/tests/lib/` and are not executed as suites.
- Each new suite imports the same world, owns its own process and reports its own pass/fail result. No suite depends on the order another suite ran.
- Helper-first is the dependency order for source changes. It is not a requirement to run helpers as a test before cases.
- Keep controls with the tested rule. Update source selectors and fixture copies when a rule moves. A sed edit that no longer matches is not a control.
- `lane-mail-check-overseer-tool.test.sh`, Copilot, compact and usage suites already consume the shared world. Their controls also require review when production bodies move.
- `session-rows.test.sh` uses its own session fixtures and first-line helper. It validates row wrapper/writer integration. Its row format owner remains `session-rows.sh`.
- Run the source and render/package checks through the repository's existing entries. Do not add a byte checker, dependency map, cache, or runner for these cuts.

### Documentation required by later implementation

This report changes no documentation other than itself. The production cuts must update references that name code placement or ownership in the same commit:

- Hook frontmatter and generated `hooks/README.md` if the executable dependency or declared safety description changes.
- `skills/orch/schemas/workflow-state.md` Recording policy and its render for the new code location of `context-told`, context gaps and sent-count readers. Keep format and retention unchanged.
- `skills/orch/references/oversee-events.md` and `overseer-session-events.md`, plus their renders, where judgement ownership or function pointers move.
- `skills/orch/DEVELOPMENT.md` for the new test division and the existing entry points. This file is not rendered.
- `docs/architecture/engine.md` and `harnesses.md` only if implementation changes delivery or dependency behavior. The proposed library location does not require such a change.

D010 and D015 fix row transport and Copilot usage/compaction interfaces. These cuts do not reverse them. Do not write a new decision record merely for Bash code placement.

## Risks, impact and likelihood

| Risk | Real-use impact and likelihood | Mitigation |
| --- | --- | --- |
| Fix exceeds file ceiling | Commit chain blocks that fix. Conditional on growth larger than the measured remaining room; no count of future fixes is known | Land measured concern cuts outside an unrelated fix. Keep source and render budgets together. |
| New library is absent from install | Named overseer can lose context judgement while still running. Directly reachable if a source-only cut lands without its skill render or a fixture masks the missing installed file | Existing skill subtree delivery, source/render inventory update, actual install test, missing/malformed-library controls and keyed gap output. |
| Shared identity is re-derived | Another pane can consume overseer mail or meet somebody else's marks. Requires a disagreement in root, server start, pane or healed launch home | Keep the identity cache/heal owner in the controller. Reuse launch library's definitions. Keep alternate-pane, restarted-server and lost-record controls. |
| Tool policy mutates caller's role/item | Following mailbox read can select the wrong mailbox. Reachable on deliver if the subshell boundary is removed | Preserve the subshell and test a mark or gap beside delivered mail. |
| Acknowledgement or told record moves before output | Directive or gap can be marked consumed without reaching the model. Requires interruption or failed output during that interval | Keep the one output transaction and existing killed-hook/output controls. |
| Split suite relies on an earlier suite's fixture | CI becomes order-dependent or fails under `set -u`. Directly reachable because the current main suite defines helpers and globals between its rows | P1 moves definitions first. Each new suite runs alone in a fresh process. Keep private fault setup with its case. |
| Mutant still targets old donor file | Test can appear to pass without exercising relocated guard. Directly reachable after moving a body | Assert edit matches, mutate a copied runtime library, and install that copy into the case's orch tree. |
| Watch module resets state on source or omits memo reset | Watch repeats or misses events, drains mail while recovery runs, or judges current account from an earlier pass. Requires a load/reset/return boundary change | Definition-only import. Preserve baseline owner, long-pass reset, mail gate and `LONG_RETURNS`. Run lifecycle, mail, accounts and recovery controls together. |
| Unknown measurement is treated as room | Lane or overseer can reach its context/account limit without a handoff warning. Requires a parse/load/read fault to become a passing default | Preserve keyed gap paths and existing shared judges. No new arithmetic or below-mark fallback. |
| Copilot predecessor record remains in the same pane | Watch can temporarily read the predecessor's gap until the replacement writes its first reading. The source explicitly documents this when no SessionStart row exists | Do not claim the extraction fixes it. Preserve current behavior and its tests. A session-identity policy change needs its own requirement. |

No split fixes missing Claude statusLine recording or mailbox-age wedge detection. Those are separate KEN-2174 proposals with different behavior and false-positive risks. This report does not fold them into packaging work.

## Reply to proposal c256f038

- **Hook and three renders**: accept a concern extraction, with P7's exact measured cuts. Keep the controller and shared identify/heal decision. Apply the same source delta to all tracked hook renders.
- **Oversee-watch**: accept P8. Move its overseer chain and mail gate together. Keep the account-read helper shared because non-overseer consumers use it.
- **Main hook suite**: accept P1-P6. The suite contains mailbox, marks, Pi rows, idle, overseer Stop and peer-mail cases. The measured partitions each fit below the approximate 64 KB test guideline with the stated new-code budgets.
- **Helper-first order**: required for source relocation. Shared definitions go into the existing world before cases move. Do not source a suite, copy its helpers into each new suite, or impose test execution order.
- **Proposed overseer units**: use one hook overseer-policy library and one watch overseer-check library. Retain hook identity/heal and existing durable libraries. Separate overseer mark/wedge/recovery files would still share one session and baseline and would add call boundaries without separate lifetimes.
- **204800-byte ceiling**: confirmed from the default commit-guards byte-ceiling setting, not doc-limits. Current files are below it. The source supports a conditional future blocked-edit risk, not the prediction that a specified number of fixes will fail.

## Files and handoff

### Files to modify in follow-ups

- `hooks/tests/lane-mail-check.test.sh` and `hooks/tests/lib/lane-mail-world.sh`.
- Existing lane-mail suites where relocated controls or fixture installation paths change.
- `hooks/lane-mail-check.sh` and its `.claude`, `.codex`, and `.pi/kendex` renders.
- `skills/orch/scripts/oversee-watch` and `.agents/skills/orch/scripts/oversee-watch`.
- `.kendex-generated.json` and the applicable docs/renders listed above.

### New files

- `hooks/tests/lane-mail-check-overseer-stop.test.sh`.
- `hooks/tests/lane-mail-check-handoff.test.sh`.
- `hooks/tests/lane-mail-check-idle.test.sh`.
- `hooks/tests/lane-mail-check-overseer-mail.test.sh`.
- `hooks/tests/lane-mail-check-pi-rows.test.sh`.
- `skills/orch/scripts/lib/lane-mail-overseer.sh` and its `.agents` render.
- `skills/orch/scripts/lib/oversee-watch-overseer.sh` and its `.agents` render.

### Execution-critical files

- `hooks/lane-mail-check.sh`: call order, shared identity and output transaction.
- `hooks/tests/lib/lane-mail-world.sh`: fixture lifetime and safe runtime-library mutations.
- `hooks/tests/lane-mail-check.test.sh`: measured donor rows and controls.
- `skills/orch/scripts/oversee-watch`: baseline, pass memo and recovery/mail ordering.
- `skills/orch/scripts/lib/lane-context.sh`: existing context path, format and arithmetic owner.

### Rollback

Revert each cut with its renders and inventory entries. Suite cuts can revert without touching runtime. For a production cut, restore donor bodies and remove the new library/import together. Keep mail cursors, handoff records, context files and row files intact. The plan changes no durable format, so rollback needs no data migration.

### TPM handoff

A TPM handoff is needed only if the owner accepts implementation follow-ups. KEN-2130 is report-only. The calling agent owns routing these proposals, not this lane.

**Prompt for the calling agent to pass to TPM**:

> Review the P1-P8 proposals in `docs/plans/lane-mail-check-review.md` against live tracked work and owner.md § Bar. The Bar text was unavailable to the report lane. Treat the report as an audit, not authorization to create issues. If implementation is authorized, perform duplicate, placement, priority and dependency analysis through the project-management workflow. Preserve helper-first P1, suite partitions P2-P6, and the distinct production cuts P7/P8. Each accepted item needs the report's Expected delta and no behavior or threshold change. Do not fold Claude statusLine recording or mailbox-age wedge policy into these cuts. Return dispositions to the calling agent.

### Implementer handoff

**Prompt for the calling agent to pass after a cut is authorized**:

> Execute only the authorized proposal from `docs/plans/lane-mail-check-review.md`. Rebase and remeasure its source ranges against the new revision. Use semantic anchors as well as line numbers. Load project instructions and code-quality. Preserve the event, caller, identity, retry, output-before-acknowledgement, mark and durable-state contracts in the inventory. Report relocated deletions/additions separately from new or rewritten glue and controls. Follow the stated dependency and budget. Use existing test entries, render rules and generated-path inventory. Do not change thresholds, add a new registered judge, or change durable formats. Run the specified controls and install checks. Return exact files, byte deltas, validation results and any budget or contract conflict to the calling agent.
