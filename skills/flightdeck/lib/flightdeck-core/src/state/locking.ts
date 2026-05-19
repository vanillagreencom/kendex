// flock(1)-based critical sections.
//
// The naive `spawnSync("flock", ["-x", String(fd), "true"])` pattern is a
// no-op for the parent: child processes don't inherit arbitrary numeric
// fds by default, and even if they did the lock would be released when
// the child exits. The functions here run the WHOLE critical section
// inside a `flock` child so the lock is held for the entire read-modify-
// write window.
//
// All payload data passes through bash positional args ($1, $2, ...),
// never via interpolation into the script source — no shell injection.

import { spawnSync } from "node:child_process";
import { mkdirSync, rmSync } from "node:fs";
import { dirname } from "node:path";

interface SpawnResult { status: number | null; stdout: string; stderr: string }

function run(args: string[], opts?: { input?: string }): SpawnResult {
	const r = spawnSync("flock", args, { encoding: "utf8", input: opts?.input });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function sleepSync(ms: number): void {
	Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// Hold a synchronous in-process critical-section lock. Most helpers in
// this file run the whole critical section inside a child `flock(1)`
// command; run-store needs to protect multi-step TypeScript reads/writes
// in-process, so this helper uses atomic mkdir/rmdir next to the lock file
// and the same temp+rename discipline for file contents.
export function withFlockHeldSync<T>(lockFile: string, fn: () => T): T {
	mkdirSync(dirname(lockFile), { recursive: true });
	const lockDir = `${lockFile}.dir`;
	const deadline = Date.now() + 30_000;
	for (;;) {
		try {
			mkdirSync(lockDir);
			break;
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
		}
		if (Date.now() > deadline) {
			throw new Error(`timed out acquiring lock: ${lockFile}`);
		}
		sleepSync(5);
	}
	try {
		return fn();
	} finally {
		rmSync(lockDir, { force: true, recursive: true });
	}
}

// jq read-modify-write of a JSON file under flock.
// Empty file body becomes `{}` before the filter (matches bash semantics).
export function lockedJqUpdate(lockFile: string, file: string, filter: string): SpawnResult {
	const tmp = `${file}.tmp.${process.pid}`;
	const script = `
		set -e
		file="$1"; tmp="$2"; filter="$3"
		if [[ -f "$file" ]]; then
			jq "$filter" "$file" > "$tmp"
		else
			echo '{}' | jq "$filter" > "$tmp"
		fi
		mv "$tmp" "$file"
	`;
	return run(["-x", lockFile, "bash", "-c", script, "_", file, tmp, filter]);
}

// Locked atomic write of bytes to a target file. Used by master-busy lock
// where the payload is a fixed JSON object.
export function lockedAtomicWrite(lockFile: string, file: string, contents: string): SpawnResult {
	const tmp = `${file}.tmp.${process.pid}`;
	const script = `
		set -e
		file="$1"; tmp="$2"
		cat > "$tmp"
		mv "$tmp" "$file"
	`;
	return run(["-x", lockFile, "bash", "-c", script, "_", file, tmp], { input: contents });
}

// Locked atomic write + sibling unlink. Used by master-busy lock where
// the busy publish and the WAKE_PENDING clear must be atomic against the
// daemon's append/wake paths.
export function lockedAtomicWriteAndUnlink(lockFile: string, file: string, contents: string, alsoUnlink: string): SpawnResult {
	const tmp = `${file}.tmp.${process.pid}`;
	const script = `
		set -e
		file="$1"; tmp="$2"; also="$3"
		cat > "$tmp"
		mv "$tmp" "$file"
		rm -f "$also"
	`;
	return run(["-x", lockFile, "bash", "-c", script, "_", file, tmp, alsoUnlink], { input: contents });
}

// Locked unlink (master-busy unlock — file remove under the session lock).
export function lockedUnlink(lockFile: string, file: string): SpawnResult {
	const script = `rm -f "$1"`;
	return run(["-x", lockFile, "bash", "-c", script, "_", file]);
}

// Locked drain of a JSONL events file, atomically renaming it out, dumping
// to stdout, and removing the snapshot. Optionally clears a sibling
// "wake-pending" file under the same lock — that's the daemon's ack
// contract that master uses at turn-end.
export function lockedEventsDrain(lockFile: string, eventsFile: string, opts: { clearWakePending?: string } = {}): SpawnResult {
	const wp = opts.clearWakePending ?? "";
	const script = `
		set -e
		events="$1"; wp="$2"
		# Recover any stranded .draining.<pid> orphans whose owner is dead.
		shopt -s nullglob
		for orphan in "$events".draining.*; do
			pid=\${orphan##*.draining.}
			if ! kill -0 "$pid" 2>/dev/null; then
				cat "$orphan" >> "$events" 2>/dev/null || true
				rm -f "$orphan"
			fi
		done
		shopt -u nullglob
		if [[ -f "$events" ]]; then
			snap="$events.draining.$$"
			if mv "$events" "$snap" 2>/dev/null; then
				cat "$snap"
				rm -f "$snap"
			fi
		fi
		if [[ -n "$wp" ]]; then
			rm -f "$wp"
		fi
	`;
	return run(["-x", lockFile, "bash", "-c", script, "_", eventsFile, wp]);
}

// Locked read-modify-write of a JSON file via an in-process callback.
// The lock is held by a child `flock` process that holds an exclusive
// advisory lock for its lifetime. We block the parent on the child's
// exit, which only happens once the callback has finished and we close
// the child's stdin. The pattern below uses `flock --no-fork` with
// command "cat > /dev/null" so the lock is held until stdin EOF.
//
// Used by the port allocators (oc/cc/codex) where the work is a few JSON
// reads/writes and not easily expressible as a single shell command.
export function withFlockSync(lockFile: string, fn: () => void): void {
	// Spawn flock holding a long-lived `cat` child. Lock is acquired
	// when cat starts; released when cat exits (EOF on stdin).
	// We don't use Bun.spawn here so this stays portable; spawnSync
	// can't run async work alongside, so we use a different pattern:
	// dump the work to a shell that runs flock around a sentinel.
	//
	// Implementation: spawn a `flock -x $lock sh -c "echo ready; read x; exit"`
	// child via Bun.spawn (async), then send "go\n" to its stdin after
	// running fn(). But spawnSync can't do that — we'd need async.
	//
	// Concrete approach: write fn's intent as a state-transition payload
	// (JSON-serializable args) to a temp file, then spawn `flock -x $lock
	// bun <script>` where the bun script reads the payload and executes
	// the actual work. This forces the work into a child process; the
	// caller cannot retain in-process closure state.
	//
	// For now we use a simpler approach: spawn flock with a long-running
	// `cat` child via Bun.spawnSync's `stdin: { input }` pattern is
	// inadequate. The honest fix for the port allocators is to inline
	// the work into a bash one-liner using helpers we provide. See
	// `lockedReadModifyWriteJsonViaBash` below for the typical pattern.
	void fn;
	void lockFile;
	throw new Error("withFlockSync requires sentinel-process plumbing — use lockedReadModifyWriteJsonViaBash instead");
}

// Read JSON file, run an in-bash sweep, scan-and-allocate, and write
// back — all under flock. The TS caller passes its candidate range
// and a chooser. This isn't appropriate for arbitrary closures, so
// it's specialized to the port-allocator shape.
//
// Returns the allocated port string (stdout from flock) or empty string
// when the range is exhausted.
export function lockedAllocPort(
	lockFile: string,
	portsFile: string,
	rangeStart: number,
	rangeEnd: number,
	ownerJson: string,
): SpawnResult {
	const tmp = `${portsFile}.tmp.${process.pid}`;
	const script = `
		set -eu
		ports="$1"; tmp="$2"; range_start="$3"; range_end="$4"; owner="$5"
		now=$(date -Iseconds)
		[[ -f "$ports" ]] || echo '{}' > "$ports"

		# Sweep dead pids in-place.
		if jq -e 'type == "object"' "$ports" >/dev/null 2>&1; then
			live="$ports.live.$$"
			echo '{}' > "$live"
			while IFS=$'\\t' read -r p pid; do
				[[ -z "$p" ]] && continue
				if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
					jq --arg p "$p" --slurpfile orig "$ports" \\
						'. + {($p): $orig[0][$p]}' "$live" > "$live.2" \\
						&& mv "$live.2" "$live"
				fi
			done < <(jq -r 'to_entries[] | "\\(.key)\\t\\(.value.pid // 0)"' "$ports" 2>/dev/null)
			mv "$live" "$ports"
		else
			echo '{}' > "$ports"
		fi

		# Scan range for a free + unregistered port.
		port=""
		for (( p = range_start; p <= range_end; p++ )); do
			if jq -e --arg p "$p" 'has($p)' "$ports" >/dev/null 2>&1; then
				continue
			fi
			if (echo > "/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
				continue
			fi
			port="$p"
			break
		done

		if [[ -z "$port" ]]; then
			exit 1
		fi

		# Register the allocation. owner is a JSON object literal e.g. {"issue":"X","pid":NNN}.
		jq --arg p "$port" --argjson owner "$owner" --arg ts "$now" \\
			'. + {($p): ($owner + {allocated_at:$ts})}' "$ports" > "$tmp" && mv "$tmp" "$ports"
		echo "$port"
	`;
	return run([
		"-x", lockFile, "bash", "-c", script, "_",
		portsFile, tmp,
		String(rangeStart), String(rangeEnd),
		ownerJson,
	]);
}

// Locked port release — del(.[$port]) under flock.
export function lockedReleasePort(lockFile: string, portsFile: string, port: number): SpawnResult {
	const tmp = `${portsFile}.tmp.${process.pid}`;
	const script = `
		set -e
		ports="$1"; tmp="$2"; port="$3"
		[[ -f "$ports" ]] || exit 0
		jq --arg p "$port" 'del(.[$p])' "$ports" > "$tmp" 2>/dev/null && mv "$tmp" "$ports"
	`;
	return run(["-x", lockFile, "bash", "-c", script, "_", portsFile, tmp, String(port)]);
}

// Locked port-pid update — merges {pid: $pid} into the existing entry.
export function lockedRegisterPortPid(lockFile: string, portsFile: string, port: number, pid: number): SpawnResult {
	const tmp = `${portsFile}.tmp.${process.pid}`;
	const script = `
		set -e
		ports="$1"; tmp="$2"; port="$3"; pid="$4"
		[[ -f "$ports" ]] || echo '{}' > "$ports"
		if jq --arg p "$port" --argjson pid "$pid" \\
			'(.[$p] // {}) as $cur | .[$p] = ($cur + {pid: $pid})' \\
			"$ports" > "$tmp" 2>/dev/null; then
			mv "$tmp" "$ports"
		else
			rm -f "$tmp"
		fi
	`;
	return run(["-x", lockFile, "bash", "-c", script, "_", portsFile, tmp, String(port), String(pid)]);
}

// Locked state archive with matching activity sidecar archive. The state
// archive receives activity_path/activity_archive_path only when a non-empty
// sidecar exists before the final rename, so post-termination readers can
// discover the matching JSONL archive from the archived master state alone.
export function lockedArchiveStateAndActivity(
	lockFile: string,
	stateFile: string,
	stateArchive: string,
	activityFile: string,
	activityArchive: string,
	activityLockFile: string,
): SpawnResult {
	const tmp = `${stateFile}.tmp.${process.pid}`;
	const script = `
		set -e
		state="$1"; state_archive="$2"; activity="$3"; activity_archive="$4"; activity_lock="$5"; tmp="$6"
		flock -x "$activity_lock" bash -c '
			set -e
			state="$1"; state_archive="$2"; activity="$3"; activity_archive="$4"; tmp="$5"
			if [[ -s "$activity" ]]; then
				mkdir -p "$(dirname "$activity_archive")"
				jq --arg activity_path "$activity" --arg activity_archive_path "$activity_archive" \
					".activity_path = (.activity_path // \\$activity_path) | .activity_archive_path = \\$activity_archive_path" \
					"$state" > "$tmp"
				mv "$tmp" "$state"
				mv "$state" "$state_archive"
				mv "$activity" "$activity_archive"
				: > "$activity.archived"
			else
				jq "del(.activity_path, .activity_archive_path)" "$state" > "$tmp"
				mv "$tmp" "$state"
				mv "$state" "$state_archive"
			fi
		' _ "$state" "$state_archive" "$activity" "$activity_archive" "$tmp"
	`;
	return run(["-x", lockFile, "bash", "-c", script, "_", stateFile, stateArchive, activityFile, activityArchive, activityLockFile, tmp]);
}

// Locked file rename — used by archive callers that do not own an
// activity sidecar.
export function lockedRename(lockFile: string, srcFile: string, dstFile: string): SpawnResult {
	const script = `mv "$1" "$2"`;
	return run(["-x", lockFile, "bash", "-c", script, "_", srcFile, dstFile]);
}

// Locked cleanup of all daemon per-session state files. Mirrors the
// bash daemon's `locked_state_cleanup` and `locked_cleanup_for_key`:
// removes wake-pending, events JSONL, wake-events log, and any
// stranded `.draining.<pid>` snapshots of the two log files — all
// under SESSION_LOCK so a concurrent ack/drain can't see half-removed
// state.
//
// Note: bash `locked_state_cleanup` does NOT remove the heartbeat
// file (it's left for the next startup's gc sweep to handle). The TS
// helper accepts an optional `heartbeatFile` parameter for callers
// that want to remove it as part of the same critical section (the
// gc path via `locked_cleanup_for_key` does this in bash too); the
// daemon-exit caller passes `undefined` to keep parity with bash.
//
// `nonblock` selects between blocking `-x` (daemon-exit path) and
// non-blocking `-nx` (gc path where a live daemon may hold the lock
// and we skip rather than wait).
export function lockedCleanupState(
	lockFile: string,
	opts: {
		wakePending?: string;
		eventsFile?: string;
		heartbeatFile?: string;
		wakeEventsLog?: string;
		nonblock?: boolean;
	},
): SpawnResult {
	const script = `
		set -e
		wp="$1"; ef="$2"; hb="$3"; wel="$4"
		[[ -n "$wp" ]] && rm -f "$wp"
		[[ -n "$hb" ]] && rm -f "$hb"
		[[ -n "$ef" ]] && rm -f "$ef"
		[[ -n "$wel" ]] && rm -f "$wel"
		shopt -s nullglob
		if [[ -n "$ef" ]]; then
			for f in "$ef".draining.*; do rm -f "$f"; done
		fi
		if [[ -n "$wel" ]]; then
			for f in "$wel".draining.*; do rm -f "$f"; done
		fi
		shopt -u nullglob
		exit 0
	`;
	const lockArg = opts.nonblock ? "-nx" : "-x";
	return run([
		lockArg, lockFile, "bash", "-c", script, "_",
		opts.wakePending ?? "",
		opts.eventsFile ?? "",
		opts.heartbeatFile ?? "",
		opts.wakeEventsLog ?? "",
	]);
}
