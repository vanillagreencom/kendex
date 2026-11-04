// kendex-lane-context: the context reader of a Copilot CLI fleet session.
//
// open-terminal installs this file as the Copilot extension
// `<COPILOT_HOME>/extensions/kendex-lane-context/extension.mjs` of the home a
// Copilot fleet lane runs under, and turns on the EXTENSIONS feature that
// loads it (`enabledFeatureFlags` in that home's settings.json). Copilot runs
// it for every session on that home, as a child process whose working
// directory and environment are the session's.
//
// It joins the session through the Copilot SDK and subscribes to
// `session.usage_info`, which Copilot emits at every model call and right
// after each compaction, carrying `currentTokens` and `tokenLimit`, the prompt
// token limit. A reading of the root agent, which carries no `agentId`, is
// handed to the lane-mail-check hook run with the argument `usage`, as the
// JSON object {session_id, cwd, current_tokens, token_limit} on stdin. That
// hook decides whether the session is a launched lane's lead or the fleet
// overseer and records the reading in the session's `context.json`, which its
// turn end judges; this file only finds the hook and runs it.
//
// The hook is the one in the Copilot hook scope the session loads, the rule
// orch lib/lane-context.sh states as lane_context_copilot_hooks and
// open-terminal's launch gate asks: `<git root>/.github/hooks` where it holds
// lane-mail-check, lane-mail-compact and lane-mail-start, each `<name>.sh`
// beside its `<name>.json`, else `${COPILOT_HOME:-$HOME/.copilot}/hooks`.
// It is spelled again here because this copy runs from the Copilot home with
// no orch install beside it to ask; skills/orch/tests/copilot-lane-context.sh
// holds the two spellings to the same answers.
//
// At most one hook run is in flight, bounded by HOOK_TIMEOUT_MS, so a slow
// hook never stalls the session and readings never pile up: a reading that
// lands while one runs replaces the one queued behind it.
//
// The hook runs apart from the session, so nothing orders its run before the
// session's next agentStop, whose turn end would read the earlier record. So
// every root event on a session whose hook scope resolves first leaves the
// session's pending marker, `~/.cache/lane-mail/copilot-usage/<session id>`,
// beside the lead records lane-mail-check keeps under `~/.cache/lane-mail`,
// before any branch that can return, an unreadable reading included; the turn
// end judges a session whose marker stands unmeasured, never its earlier
// record as room. That directory is orch lib/lane-context.sh's
// lane_context_copilot_pending_dir, which open-terminal's launch gate makes
// and proves writable before a fleet lane starts, spelled again here as
// PENDING_DIR; skills/orch/tests/copilot-lane-context.sh holds the two
// spellings to the same directory. Only a run that exits 0 carrying the
// newest root event removes the marker: a run that fails, or one a later event
// overtook, readable or not, leaves it standing until a later reading is
// recorded.
//
// A gap is written to the session timeline at level warning, once per
// distinct first line:
//   kendex-lane-context: hooks-missing=<project scope>,<global scope>, only
//   for a session that can be a fleet session (fleetSession); any other runs
//   no hook and says nothing
//   kendex-lane-context: reading=unreadable, with the marker left standing
//   kendex-lane-context: pending-unwritten=<marker>, a marker that could not
//   be written in a directory the launch gate proved writable, so a turn end
//   during the run reads the earlier record
//   kendex-lane-context: pending-unremoved=<marker>, a marker that could not
//   be removed, so every turn end judges the session unmeasured
//   kendex-lane-context: usage-spawn=<error code>
//   kendex-lane-context: usage-signal=<signal>
//   kendex-lane-context: usage-exit=<status>, for a hook that wrote nothing
//   the hook's own keyed stderr, `lane-mail-check: <key>=<value>`, for any
//   other exit that is not 0
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { joinSession } from "@github/copilot-sdk/extension";

const KEY = "kendex-lane-context";
// lane-mail-start is here for the lead record it writes at sessionStart, which
// lane-mail-check needs before it takes a reading this file hands it as the
// lead's.
const HOOKS = ["lane-mail-check", "lane-mail-compact", "lane-mail-start"];
// The lane-mail-check hook's own timeout: the longest a run of it is budgeted.
const HOOK_TIMEOUT_MS = 30000;

const session = await joinSession({});
const cwd = process.cwd();
const PENDING_DIR = join(homedir(), ".cache", "lane-mail", "copilot-usage");
const pending = join(PENDING_DIR, session.sessionId);

const logged = new Set();
function gap(text) {
  const first = text.split("\n", 1)[0];
  if (logged.has(first)) return;
  logged.add(first);
  // The timeline is the one place this process can report to; a log call that
  // fails leaves stderr, which Copilot keeps in its own log.
  session.log(text, { level: "warning" }).catch((error) => {
    process.stderr.write(`${first}\n${error}\n`);
  });
}

function holdsHooks(dir) {
  return HOOKS.every((name) => existsSync(join(dir, `${name}.sh`)) && existsSync(join(dir, `${name}.json`)));
}

// Whether this session can be one lane-mail-check's session gate passes, from
// the inputs that gate starts from: a lane is named by LANE_MAIL_ITEM or its
// branch under the checkout's `tmp/lane-mail` mailbox root, and the overseer
// runs in a tmux pane. Copilot runs this extension for every session on the
// home, so a session with none of them is no fleet session, and hooks missing
// there are nothing to report.
function fleetSession(root) {
  if (process.env.LANE_MAIL_ITEM || (process.env.TMUX && process.env.TMUX_PANE)) return true;
  if (root === null) return false;
  try {
    return statSync(join(root, "tmp", "lane-mail"), { throwIfNoEntry: false })?.isDirectory() === true;
  } catch {
    // A mailbox root that cannot be examined may be a lane's, so the gap is
    // reported rather than passed over.
    return true;
  }
}

// The hook scope this session loads, or null with no scope holding every hook.
function hookScope() {
  const scopes = [];
  const git = spawnSync("git", ["-C", cwd, "rev-parse", "--show-toplevel"], { encoding: "utf8" });
  const root = git.status === 0 && git.stdout.trim() !== "" ? git.stdout.trim() : null;
  if (root !== null) scopes.push(join(root, ".github", "hooks"));
  scopes.push(join(process.env.COPILOT_HOME || join(homedir(), ".copilot"), "hooks"));
  const scope = scopes.find(holdsHooks);
  if (scope === undefined) {
    if (!fleetSession(root)) return null;
    gap(`${KEY}: hooks-missing=${scopes.join(",")}\n` +
      "no Copilot hook scope this session loads holds lane-mail-check, lane-mail-compact and lane-mail-start, " +
      "so its context is not recorded and its turn end judges it unmeasured; install all three hooks in one of these scopes");
    return null;
  }
  return scope;
}

function markPending() {
  try {
    mkdirSync(PENDING_DIR, { recursive: true });
    writeFileSync(pending, "");
  } catch (error) {
    gap(`${KEY}: pending-unwritten=${pending}\n` +
      "the marker that tells this session's turn end a reading is on its way could not be written, " +
      `so a turn end while the hook runs judges the earlier recorded reading: ${error.message}`);
  }
}

function clearPending() {
  try {
    rmSync(pending, { force: true });
  } catch (error) {
    // A path through a file that is no directory holds no marker to remove.
    if (error.code === "ENOTDIR") return;
    gap(`${KEY}: pending-unremoved=${pending}\n` +
      "this session's reading is recorded and its pending marker could not be removed, " +
      `so its turn ends judge its context unmeasured until the marker is removed: ${error.message}`);
  }
}

let running = false;
let queued = null;
// The number of root events on a resolved hook scope so far; the last one is
// the event a run must carry to remove the marker.
let latest = 0;

// queued: {scope, reading, seq}, the hook scope decided when the reading
// landed and the number of its event.
function drain() {
  if (running || queued === null) return;
  const { scope, reading, seq } = queued;
  queued = null;
  running = true;
  const child = spawn("bash", [join(scope, "lane-mail-check.sh"), "usage"], {
    cwd,
    env: process.env,
    stdio: ["pipe", "ignore", "pipe"],
    timeout: HOOK_TIMEOUT_MS,
  });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  // A hook that exits before reading its stdin closes the pipe; its exit
  // status is what reports that run.
  child.stdin.on("error", () => {});
  child.stdin.end(JSON.stringify(reading));
  let spawnError = null;
  child.on("error", (error) => { spawnError = error; });
  child.on("close", (code, signal) => {
    if (spawnError !== null) {
      gap(`${KEY}: usage-spawn=${spawnError.code ?? "unknown"}\n` +
        `bash could not run ${join(scope, "lane-mail-check.sh")}, so this reading is not recorded: ${spawnError.message}`);
    } else if (signal !== null) {
      gap(`${KEY}: usage-signal=${signal}\n` +
        `the lane-mail-check hook did not finish within ${HOOK_TIMEOUT_MS} ms and was stopped, so this reading is not recorded`);
    } else if (code !== 0) {
      gap(stderr.trim() || `${KEY}: usage-exit=${code}\nthe lane-mail-check hook exited ${code} and wrote nothing`);
    } else if (seq === latest) {
      clearPending();
    }
    running = false;
    drain();
  });
}

function whole(value) {
  return Number.isInteger(value) && value >= 0;
}

session.on("session.usage_info", (event) => {
  // A subagent's window is its own, not the session's.
  if (event.agentId) return;
  const { currentTokens, tokenLimit } = event.data ?? {};
  const readable = whole(currentTokens) && whole(tokenLimit) && tokenLimit !== 0;
  const scope = hookScope();
  // No hook judges a session with no scope, so it has no marker to leave.
  if (scope === null) return;
  markPending();
  latest += 1;
  if (!readable) {
    gap(`${KEY}: reading=unreadable\n` +
      "a session.usage_info event carried no whole currentTokens and tokenLimit, so it is not recorded " +
      "and the session's turn end judges it unmeasured until a later reading is recorded");
    return;
  }
  queued = { scope, seq: latest, reading: { session_id: session.sessionId, cwd, current_tokens: currentTokens, token_limit: tokenLimit } };
  drain();
});
