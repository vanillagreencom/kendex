# Orchestration, execution and mail have separate owners

Read before changing what orch, agent-runtime or mailbox does for another, or adding a call between them: a launch, a stop, a delivery into a session, a write to an item or fleet record, a mail send, read or cursor move.

## The approach

Three packages run agent work on a repository, and each owns one kind of state.

- orch owns the work. Its runtime, `skills/orch/runtime/`, holds the item records and the fleet record, every transition over them, and every decision: admit, launch, wake, close, accept, hold.
- agent-runtime owns the session. Its runtime, `skills/agent-runtime/runtime/`, builds the harness command, wraps it in its confinement, opens the window, holds the process and session identity, types into the pane and stops by identity. It holds no tracker, review, report or fleet policy.
- mailbox owns the messages. Its program, `skills/mailbox/scripts/lane-mail`, writes every box, judges every delivery key and moves every read cursor.

The manifests set the direction. `skills/orch/runtime/Cargo.toml` depends on the agent-runtime crate, and `skills/orch/SKILL.md` requires agent-runtime and mailbox. The agent-runtime crate depends on neither, so it cannot name an orch type. `skills/mailbox/SKILL.md` declares orch and agent-runtime optional, and `lane-mail` runs their programs only for the verbs that need them. No runtime links mailbox code: each runs `lane-mail` and decodes its reply.

## Why

Each owner keeps a truth the others act on. orch's records say what is open, owned and finished, so an overseer or the scheduler never acts on a guess. agent-runtime's recorded identities say which processes a stop may signal; a stop by process name or by a pid alone can signal a process the session does not own. mailbox's cursor says what a reader has seen; a cursor moved before the answer that carries the lines is written loses those lines.

One owner per truth also keeps each package usable without the others. A caller with no repository workflow uses agent-runtime: `second-opinion` picks an account through `agent-runtime accounts pick`. Owner questions and notices work with mailbox installed alone, because mailbox writes no orch state.

## Rules

- Do decide in an orch transition and act in an effect. A transition under `ops/` persists the intent beside the record change it judges and never runs the effect. `effects::run` runs the effect and records what it observed through `record-outcome`. One intent per target may be open, and a repeated request reconciles it, so a crash between the decision and the act leaves an intent to re-observe, never a second effect.
- Do record before an act that cannot be taken back: the launch phase before the window opens and before each wait, the wake's mark before it types, the owed directive before a session send.
- Do reach the host from orch only through agent-runtime's operation handle, `agent_runtime::effects::Operation`, which `skills/orch/runtime/src/effects/lane_operation.rs::fn open` opens. `skills/orch/runtime/clippy.toml` lists agent-runtime's tmux, process, session, trust, job and record primitives and `std::process::Command` as disallowed methods. The `skill-tests` workflow runs `cargo clippy --all-targets -- -D warnings` on each package runtime, which refuses an ordinary call of one outside the functions that carry a reviewed allowance. A new acting function in agent-runtime joins that list in the same change.
- Do let orch choose and agent-runtime spell. orch picks the harness, account, model and brief, and derives what the harness may write in `skills/orch/runtime/src/effects/grants.rs`. Never put a harness flag on a command line, read a harness's session files or compose a stop outside agent-runtime: `skills/agent-runtime/runtime/src/launch.rs::pub fn build` is the one command builder, and it wraps the command in the confinement `confine.rs` derives from those grants.
- Do change an item record or a lane only in an orch transition. agent-runtime's journal writes an intent's frame and no member that frame does not own; the lane an outcome moves is moved by the arm orch passes, `skills/orch/runtime/src/ops/mod.rs::fn engine_outcome_arm`.
- Do reach mail only by running `lane-mail`: orch through `skills/orch/runtime/src/mailbox.rs::pub struct Mailbox`, agent-runtime through its owner notice, `skills/agent-runtime/runtime/src/effects/job.rs::fn owner_notice`. A refusal decodes as a refusal, never as an empty mailbox. Never write a box line or move a cursor from either runtime; orch's mail duty reads a cursor file where `lane-mail` keeps it and never moves it.
- Never let mailbox write orch state. A send orch must record is recorded owed before `lane-mail` runs and stamped from the receipt the program prints, in `skills/orch/runtime/src/send.rs`. `skills/mailbox/tests/alone.sh` runs the mailbox with no orch installed.

Review holds each rule that names no list, workflow or test.

## The canonical example

A validation run's end notice, from its send to the lane's next turn, crosses the three owners in turn.

1. orch decides to tell the lane. `skills/orch/runtime/src/send.rs::fn send_notice` routes a lane with no session channel to `Mailbox::send_directive`, one run of `lane-mail send --item ITEM --directive --file F --delivery-id KEY`.
2. mailbox stores it. `lane-mail send` appends the envelope to the lane's `to-lane.jsonl` and judges the key under its lock, so a replay answers `delivery-repeated` and lands nothing.
3. orch notices it. The mail duty reads every lane box in one `drain_many` call, and `skills/orch/runtime/src/watch/mail.rs::fn lane_turn` sets an `unread` row while the box holds lines past the lane's cursor.
4. orch decides to wake the lane, and agent-runtime types. The wake duty writes its mark, then `skills/orch/runtime/src/watch/wake.rs::fn paste` runs agent-runtime's `deliver` verb. `skills/agent-runtime/runtime/src/main.rs::fn deliver` types only into a pane its judge reads idle, and confirms by a new user turn in that session's own file. The line it types tells the lane to run `lane-mail inbox`; the message never passes through agent-runtime.
5. mailbox hands the message over. At the lane's next hook, `skills/orch/runtime/src/turnend/mail.rs::pub(super) fn check` reads the unread lines with `lane-mail inbox --peek`, which moves no cursor, and carries them as context. `Ack::settle` runs `lane-mail inbox --ack COUNT` once that answer is written.

Copy this shape for a new crossing: orch decides and records, agent-runtime acts on the session, and `lane-mail` holds the message.

## Reading route

- [skills/orch/DEVELOPMENT.md](../../skills/orch/DEVELOPMENT.md): the runtime's stack, its tests and the rule for adding an effect-boundary allowance.
- [skills/agent-runtime/SKILL.md](../../skills/agent-runtime/SKILL.md): the execution contract, its verbs, outcomes and stop by identity; [skills/agent-runtime/DEVELOPMENT.md](../../skills/agent-runtime/DEVELOPMENT.md) for its build, native probe and lint.
- [skills/mailbox/SKILL.md](../../skills/mailbox/SKILL.md) and `lane-mail --help`: the verbs, envelopes, receipts and refusal keys.

## Revisit when

A second caller needs to move an item record or a lane without orch, or a harness carries messages natively so that a delivery can no longer point at `lane-mail`.

## Not governed

What a turn end answers and when the watch wakes a lane: orch's own decisions, held by its tests under `skills/orch/tests/rust/`. The runtime's stack and storage: the reading route's first entry.
