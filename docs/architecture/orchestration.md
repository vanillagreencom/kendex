# Orchestration, execution and mail have separate owners

Read before changing what orch, agent-runtime or mailbox does for another, or adding a call between them: a launch, a stop, a delivery into a session, a write to an item or fleet record, a mail send, read or cursor move.

## The approach

Three packages run agent work on a repository. Each owns one kind of state.

- orch owns the work. Its runtime, `skills/orch/runtime/`, holds the item records, the fleet record, every transition over them and every decision: admit, launch, wake, close, accept, hold. Its wake reads a provider stop's kind from agent-runtime before it continues a session.
- agent-runtime owns the session. Its runtime, `skills/agent-runtime/runtime/`, builds the harness command and wraps it in its confinement. It opens the window, holds the process and session identity, types into the pane and stops by identity. It names a stop's kind and holds the table that maps a kind to an action (`skills/agent-runtime/runtime/src/stop.rs`). Orch's overseer duty (`watch::overseer`) and its lane watch (`watch::lanes`) call that table, supplying the fleet's account ground and sending the notices. The jarvis package's own session, which needs the decision without orch, calls it through `agent-runtime controller successor --stop`. It holds no tracker, review or report policy, and no other fleet policy.
- mailbox owns the messages. Its program, `skills/mailbox/scripts/lane-mail`, writes every box, judges every delivery key and moves every read cursor.

The manifests set the direction. `skills/orch/runtime/Cargo.toml` depends on the agent-runtime crate, and `skills/orch/SKILL.md` requires agent-runtime and mailbox. The agent-runtime crate depends on neither, so it cannot name an orch type. `skills/mailbox/SKILL.md` declares orch and agent-runtime optional, and `lane-mail` runs their programs only for the verbs that need them.

## Why

Each owner keeps a truth the others act on. orch's records say what is open, owned and finished, so an overseer or the scheduler never acts on a guess. agent-runtime's recorded identities say which processes a stop may signal. A stop by process name or by a pid alone can signal a process the session does not own. mailbox's cursor says what a reader has seen. A cursor moved before the answer that carries the lines is written loses those lines.

One owner per truth also keeps each package usable alone. A caller with no repository workflow uses agent-runtime: `second-opinion` picks an account through `agent-runtime accounts pick`. Owner questions and notices work with mailbox installed alone, because mailbox writes no orch state.

## Rules

- Do decide in an orch transition and act in an effect. A transition under `ops/` persists the intent beside the record change it judges, and never runs the effect. The effect records what it observed. One intent per target may be open, and a repeated request reconciles it. A crash between the decision and the act leaves an intent to re-observe, never a second effect.
- Do record before an act that cannot be taken back: the launch phase before the window opens and before each wait, the wake's mark before it types, the owed directive before a session send.
- Do reach the host from orch only through agent-runtime's operation handle, `agent_runtime::effects::Operation`. `skills/orch/runtime/src/effects/lane_operation.rs::fn open` opens it. `skills/orch/runtime/clippy.toml` lists agent-runtime's tmux, process, session, trust, job and record primitives and `std::process::Command` as disallowed methods. The `skill-tests` workflow runs `cargo clippy --all-targets -- -D warnings` on each package runtime. It refuses an ordinary call of a listed method outside the functions that carry a reviewed allowance. A new acting function in agent-runtime joins that list in the same change.
- Do let orch choose and agent-runtime spell. orch picks the harness, account, model and brief. `skills/orch/runtime/src/effects/grants.rs` derives what the harness may write; in a seat, that is only what `skills/agent-runtime/runtime/src/harness.rs::fn home_writes` names. Never put a harness flag on a command line, read a harness's session files or compose a stop outside agent-runtime. `skills/agent-runtime/runtime/src/launch.rs::pub fn build` is the one command builder. It wraps the command in the confinement `confine.rs` derives from those grants.
- Do change an item record or a lane only in an orch transition. agent-runtime's journal writes an intent's frame and no member that frame does not own. The arm orch passes, `skills/orch/runtime/src/ops/mod.rs::fn engine_outcome_arm`, moves the lane an outcome moves.
- Do reach mail only by running `lane-mail`: orch through `skills/orch/runtime/src/mailbox.rs::pub struct Mailbox`, agent-runtime through its owner notice, `skills/agent-runtime/runtime/src/effects/job.rs::fn owner_notice`. Decode a refusal as a refusal, never as an empty mailbox. Never write a box line or move a cursor from either runtime. orch's mail duty reads a cursor file where `lane-mail` keeps it, and never moves it.
- Never let mailbox write orch state. `skills/orch/runtime/src/send.rs` records a send orch must record as owed before `lane-mail` runs, and stamps it from the receipt the program prints. `skills/mailbox/tests/alone.sh` runs the mailbox with no orch installed.

Review holds each rule that names no list, workflow or test.

## The canonical example

A validation run's end notice to a lane with no session channel is the smallest complete crossing. `skills/orch/runtime/src/send.rs::fn send_notice` sends it as one `lane-mail send --directive` with a delivery key, and mailbox answers a replay `delivery-repeated` and lands nothing. The watch sees the unread line, writes its wake mark, and runs agent-runtime's `deliver` verb from `skills/orch/runtime/src/watch/wake.rs::fn paste`. `deliver` types only into a pane it reads idle, and the typed line only tells the lane to run `lane-mail inbox`; the message never passes through agent-runtime. At the lane's next hook, `skills/orch/runtime/src/turnend/mail.rs` reads the lines with `lane-mail inbox --peek` and acknowledges them only once its answer is written.

Copy this shape for a new crossing: orch decides and records, agent-runtime acts on the session, and `lane-mail` holds the message.

## Revisit when

A second caller needs to move an item record or a lane without orch, or a harness carries messages natively, so that a delivery can no longer point at `lane-mail`.

## Not governed

What a turn end answers and when the watch wakes a lane: orch's own decisions, held by its tests under `skills/orch/tests/rust/`. The runtime's stack, storage and tests: [skills/orch/DEVELOPMENT.md](../../skills/orch/DEVELOPMENT.md).
