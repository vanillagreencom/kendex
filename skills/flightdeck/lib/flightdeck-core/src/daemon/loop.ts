// Port of flightdeck-daemon.bash::run_loop. The main poll cycle.
//
// Responsibilities (from bash daemon comments):
//   1. Pre-loop: resolve every inner pane id, refuse on master/inner
//      collisions, spawn per-harness subscribers when registry has
//      adapter metadata for the pane.
//   2. Main tick:
//      - touchHeartbeat
//      - max-lifetime check → spawn successor + exit (Option A
//        divergence documented in lifecycle.ts)
//      - sessionAlive bail
//      - refresh tmux pane cache
//      - master pane_alive bail
//      - clear_stale_wake_pending (revert in-flight state on crash)
//      - drain wake-events log; classify + append events for canonical
//        adapter wakes
//      - for each inner pane: subscriber-liveness watchdog, bell
//        branch, hash-change branch, stable-age branch
//      - heartbeat log line every HEARTBEAT_TICKS
//      - if tick_reasons: wake_master + record NOTIFIED_HASH +
//        clear_bell_for_window on success

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import {
	fdBusyFile,
	fdEventsFile,
	fdHeartbeatFile,
	fdLogFile,
	fdSessionLock,
	fdWakePending,
	fdWakeEventsLog,
} from "../paths/daemon.ts";
import {
	ocSubscriberPidFile,
} from "../paths/oc.ts";
import { ccSubscriberPidFile } from "../paths/cc.ts";
import { piSubscriberPidFile } from "../paths/pi.ts";
import { cxSubscriberPidFile } from "../paths/codex.ts";
import { isCanonicalTag, appendEvent } from "./events.ts";
import { BG_TASK_EXIT_CLASSIFIER_TAG } from "../events/bg-task-exit.ts";
import {
	emitActivityForWakeRow,
	emitSubscriberDead,
	emitSubscriberReattached,
	emitSubscriberStarted,
	type DaemonActivityContext,
	type WakeEventRow,
} from "./activity.ts";
import { clearStaleWakePending, isMasterBusy } from "./busy.ts";
import { clearBellForWindow, wakeMaster, resolvePiMasterPid } from "./wake.ts";
import { PaneCache, capturePane, captureHash12, classifyBuffer, resolvePaneId, sessionAlive, stabilityForHarness } from "./pane-meta.ts";
import { daemonLog, daemonWarn } from "./log.ts";
import { setDaemonExitReason, setDaemonMasterId, touchHeartbeat } from "./lifecycle.ts";
import { drainOcWakeEvents } from "./subscribers/drain.ts";
import {
	spawnOcSubscriber,
	spawnCcSubscriber,
	spawnPiSubscriber,
	spawnCxSubscriber,
} from "./subscribers/spawn.ts";
import {
	reconcileIntervalFromEnv,
	reconcileTrackedEntries,
} from "./reconcile.ts";
import {
	entryKindForPane,
	extractFlag,
	liveInnerArgsForHandoff,
	listTrackedEntriesForReconcile,
	resolveMeta,
	resolvePaneTargetForEntry,
} from "./pane-registry.ts";
import { reapSubscriber } from "./subscribers/reap.ts";
import {
	bellWakeIntervalFromEnv,
	makeBellWakeState,
	recordBellWake,
	shouldEmitBellWake,
	shouldEmitBgTaskExitWake,
} from "./wake-filter.ts";
import {
	recoveryHintPath,
	resolveMasterPidSafe,
	writeRecoveryHint,
} from "./recovery-hint.ts";
import {
	ownerCgroupProbeEnabled,
	ownerMemHeartbeatFields,
	probeOwnerCgroupMem,
} from "./owner-cgroup-mem.ts";
import { OC_LAST_ASSISTANT_JQ } from "../paths/oc.ts";
import { CC_LAST_ASSISTANT_JQ } from "../paths/cc.ts";
import { PI_LAST_ASSISTANT_JQ } from "../paths/pi.ts";
import { CX_LAST_ASSISTANT_JQ } from "../paths/codex.ts";

export interface RunLoopOpts {
	stateDir: string;
	sessionId: string;
	sessionKey: string;
	sessionName: string;
	masterTarget: string;
	masterHarness: string;
	innerTargets: string[];
	innerHarnesses: string[];   // parallel array; "" entries default to FD_HARNESS or harness
	classifierBin: string;
	defaultHarness: string;
	pollSec: number;
	stabilitySec: number;
	captureLines: number;
	graceSec: number;
	heartbeatTicks: number;
	maxLifetime: number;        // 0 disables
	wakePendingTtl: number;
	masterTurnTtl: number;
	verbose: boolean;
	debugPane: string;
	fromHandoff: boolean;
	scriptPath: string;
	origArgs: string[];
	paneRegistryBin: string;    // path to pane-registry executable for resolve_*_meta
	activity?: DaemonActivityContext;
}

interface TickPending {
	paneId: string;
	hash: string;
	tag: string;
	isBell: boolean;
}

// pane-registry helpers were moved to ./pane-registry.ts (W5 reviewer
// follow-up B4). Sibling modules should import them from there directly.

export async function runLoop(opts: RunLoopOpts): Promise<void> {
	const sessionLock = fdSessionLock(opts.stateDir, opts.sessionKey);
	const wakePending = fdWakePending(opts.stateDir, opts.sessionKey);
	const eventsFile = fdEventsFile(opts.stateDir, opts.sessionKey);
	const busyFile = fdBusyFile(opts.stateDir, opts.sessionKey);
	const heartbeatFile = fdHeartbeatFile(opts.stateDir, opts.sessionKey);
	const wakeEventsLog = fdWakeEventsLog(opts.stateDir, opts.sessionKey);
	const logFile = fdLogFile(opts.stateDir, opts.sessionKey);

	const log = (tag: string, msg: string): void => daemonLog(logFile, tag, msg);
	const warn = (tag: string, msg: string): void => daemonWarn(logFile, tag, msg);
	const activity = opts.activity ?? { sessionId: opts.sessionName };

	// State maps mirror the bash declare -A arrays.
	const lastHash = new Map<string, string>();
	const hashSince = new Map<string, number>();
	const notifiedHash = new Map<string, string>();
	const lastBellHash = new Map<string, string>();
	const lastGoneLog = new Map<string, number>();
	const firstSeen = new Map<string, number>();
	const paneHarness = new Map<string, string>();
	const ocPaneTarget = new Map<string, string>();
	const ocSubscribed = new Map<string, true>();
	const lastEventKey = new Map<string, true>();
	// Round-4 #10: cache subscriber pids in memory at spawn time so the
	// per-tick liveness check is process.kill(pid, 0) rather than
	// existsSync + readFileSync + parse on the pid file.
	const subscriberPid = new Map<string, number>();
	// Round-4 #11: track per-pane activity flag to skip capture-pane
	// when nothing changed since the last tick. A low-frequency sweep
	// (every 30 ticks) still captures so we catch missed signals.
	const lastActivityFlag = new Map<string, number>();
	let captureSweepCounter = 0;

	if (opts.innerHarnesses.length > 0 && opts.innerHarnesses.length !== opts.innerTargets.length) {
		process.stderr.write(`Error: --inner-harnesses count (${opts.innerHarnesses.length}) != --inner count (${opts.innerTargets.length})\n`);
		process.exit(2);
	}

	// Resolve every inner target → pane_id. Refuse master/inner
	// collision; refuse duplicate inner ids.
	const masterId = resolvePaneId(opts.masterTarget);
	if (!masterId) {
		process.stderr.write(`Error: cannot resolve master pane '${opts.masterTarget}'\n`);
		process.exit(2);
	}
	setDaemonMasterId(masterId);
	const innerIds: string[] = [];
	const seenInner = new Set<string>();
	for (let i = 0; i < opts.innerTargets.length; i += 1) {
		const t = opts.innerTargets[i]!;
		const id = resolvePaneId(t);
		if (!id) {
			if (opts.fromHandoff) {
				warn("handoff-inner-stale", `dropping stale handoff inner pane '${t}' (cannot resolve)`);
				continue;
			}
			process.stderr.write(`Error: cannot resolve inner pane '${t}'\n`);
			process.exit(2);
		}
		if (id === masterId) {
			process.stderr.write(`Error: inner pane '${t}' resolves to master pane id ${masterId} (feedback loop)\n`);
			process.exit(2);
		}
		if (seenInner.has(id)) {
			process.stderr.write(`Error: duplicate inner pane id ${id} (target '${t}' resolves to already-tracked pane)\n`);
			process.exit(2);
		}
		seenInner.add(id);
		innerIds.push(id);
		paneHarness.set(id, opts.innerHarnesses[i] || opts.defaultHarness || "");
		ocPaneTarget.set(id, t);
	}

	// Spawn per-harness subscribers when adapter metadata is available.
	const baseEnv = {
		stateDir: opts.stateDir,
		sessionLock,
		wakeEventsLog,
		logFile,
		classifier: opts.classifierBin,
		parentPid: process.pid,
	};

	function trySpawnSubscriberForPane(paneId: string, target: string, harness: string): boolean {
		switch (harness) {
			case "opencode": {
				const meta = resolveMeta(opts.paneRegistryBin, "oc-attach-args", target);
				const url = extractFlag(meta, "--url");
				const sid = extractFlag(meta, "--session");
				if (!url || !sid) return false;
				const { pid, reattached } = spawnOcSubscriber({ ...baseEnv, sessionKey: opts.sessionKey, paneId, ocUrl: url, sessionId: sid, ocLastAssistantJq: OC_LAST_ASSISTANT_JQ, log });
				ocSubscribed.set(paneId, true);
				subscriberPid.set(paneId, pid);
				emitSubscriberLifecycle(activity, reattached, "opencode", paneId, pid);
				return true;
			}
			case "claude": {
				const meta = resolveMeta(opts.paneRegistryBin, "cc-channel-args", target);
				const transcript = extractFlag(meta, "--transcript");
				if (!transcript) return false;
				const { pid, reattached } = spawnCcSubscriber({ ...baseEnv, sessionKey: opts.sessionKey, paneId, transcript, ccLastAssistantJq: CC_LAST_ASSISTANT_JQ, log });
				ocSubscribed.set(paneId, true);
				subscriberPid.set(paneId, pid);
				emitSubscriberLifecycle(activity, reattached, "claude", paneId, pid);
				return true;
			}
			case "pi": {
				const meta = resolveMeta(opts.paneRegistryBin, "pi-bridge-args", target);
				const piPid = extractFlag(meta, "--pid");
				const piSocket = extractFlag(meta, "--socket");
				if (!piPid && !piSocket) return false;
				const entryKind = entryKindForPane(opts.paneRegistryBin, paneId);
				const { pid, reattached } = spawnPiSubscriber({ ...baseEnv, sessionKey: opts.sessionKey, paneId, piPid, piSocket, piLastAssistantJq: PI_LAST_ASSISTANT_JQ, entryKind, entryHarness: "pi", log });
				ocSubscribed.set(paneId, true);
				subscriberPid.set(paneId, pid);
				emitSubscriberLifecycle(activity, reattached, "pi", paneId, pid);
				return true;
			}
			case "codex": {
				const meta = resolveMeta(opts.paneRegistryBin, "cx-bridge-args", target);
				const cxUrl = extractFlag(meta, "--url");
				const threadId = extractFlag(meta, "--thread");
				if (!cxUrl || !threadId) return false;
				const { pid, reattached } = spawnCxSubscriber({ ...baseEnv, sessionKey: opts.sessionKey, paneId, cxUrl, threadId, cxLastAssistantJq: CX_LAST_ASSISTANT_JQ, log });
				ocSubscribed.set(paneId, true);
				subscriberPid.set(paneId, pid);
				emitSubscriberLifecycle(activity, reattached, "codex", paneId, pid);
				return true;
			}
			default:
				return false;
		}
	}

	for (const id of innerIds) {
		const h = paneHarness.get(id) ?? "";
		const target = ocPaneTarget.get(id) ?? "";
		if (h) trySpawnSubscriberForPane(id, target, h);
	}

	// Auto-detect master harness when caller didn't pass --master-harness.
	let masterHarness = opts.masterHarness;
	if (!masterHarness) {
		const pid = resolvePiMasterPid(masterId);
		if (pid !== null) {
			masterHarness = "pi";
			log("master-harness", "auto-detected master harness=pi via pi-bridge list cwd match");
		}
	}

	log("start", `pid=${process.pid} session_id=${opts.sessionId} name=${opts.sessionName} master_id=${masterId} master_harness=${masterHarness || "unknown"} inner_ids=${innerIds.join(" ")} oc_subscribed=${ocSubscribed.size}`);

	let heartbeatCounter = 0;
	const startEpoch = Math.floor(Date.now() / 1000);
	const paneCache = new PaneCache();
	void warn; void notifiedHash; void wakeEventsLog;

	// vstack#68: per-pane bell-wake rate limit + non-canonical drop. The
	// state is in-memory only (a daemon restart starts fresh, which is
	// the right thing — the user wants to be re-notified about an unread
	// canonical bell after a restart).
	const bellWakeState = makeBellWakeState();
	const bellWakeIntervalSec = bellWakeIntervalFromEnv();

	// vstack#72: probe owner cgroup memory inside the heartbeat cadence.
	// Gated by FD_HEARTBEAT_OWNER_CGROUP (default on); silent on any
	// failure so non-Linux / no-cgroup-v2 hosts keep the existing line.
	const ownerCgroupProbeOn = ownerCgroupProbeEnabled();

	// vstack#59: reconcile tracked entries every FD_RECONCILE_INTERVAL_SEC
	// so the daemon picks up panes added mid-session without restart.
	const reconcileIntervalSec = Math.max(1, Math.floor(reconcileIntervalFromEnv()));
	let lastReconcileEpoch = Math.floor(Date.now() / 1000);
	function reconcileNow(reason: string): void {
		const entries = listTrackedEntriesForReconcile(opts.paneRegistryBin, opts.defaultHarness);
		const result = reconcileTrackedEntries({
			listTrackedEntries: () => entries,
			activePaneIds: () => innerIds.values(),
			spawnFor: (entry) => {
				const target = entry.adapterMeta?.ocUrl || entry.paneId; // fallback if pane-target unknown
				const resolvedTarget = resolvePaneTargetForEntry(opts.paneRegistryBin, entry.paneId) || target;
				const spawned = entry.harness ? trySpawnSubscriberForPane(entry.paneId, resolvedTarget, entry.harness) : false;
				if (spawned) {
					paneHarness.set(entry.paneId, entry.harness);
					ocPaneTarget.set(entry.paneId, resolvedTarget);
					innerIds.push(entry.paneId);
					seenInner.add(entry.paneId);
					return { spawned: true };
				}
				return { spawned: false, reason: entry.harness ? "no-adapter-meta" : "missing-harness" };
			},
			reap: (paneId) => {
				reapSubscriberForPane(paneId, "entry-removed");
				const idx = innerIds.indexOf(paneId);
				if (idx >= 0) innerIds.splice(idx, 1);
				seenInner.delete(paneId);
				paneHarness.delete(paneId);
				ocPaneTarget.delete(paneId);
			},
			log: (tag, msg) => log(tag, `${msg} reason=${reason}`),
		});
		return void result;
	}

	function subscriberLogFor(harness: string, paneId: string): string {
		const safe = paneId.replace(/^%/, "");
		switch (harness) {
			case "opencode": return `${logFile}.oc-sub-${safe}`;
			case "claude":   return `${logFile}.cc-sub-${safe}`;
			case "pi":       return `${logFile}.pi-sub-${safe}`;
			case "codex":    return `${logFile}.cx-sub-${safe}`;
			default: return "";
		}
	}

	function reapSubscriberForPane(paneId: string, reason: string): void {
		const h = paneHarness.get(paneId) ?? "";
		const pidFile = subscriberPidFor(h, paneId);
		const pid = subscriberPid.get(paneId) ?? null;
		reapSubscriber(
			{
				paneId,
				reason,
				pidFile,
				logFile: subscriberLogFor(h, paneId),
				pid,
				harness: h || undefined,
			},
			{ log },
		);
		ocSubscribed.delete(paneId);
		subscriberPid.delete(paneId);
		lastActivityFlag.delete(paneId);
		lastHash.delete(paneId);
		hashSince.delete(paneId);
		notifiedHash.delete(paneId);
		lastBellHash.delete(paneId);
		firstSeen.delete(paneId);
	}

	function subscriberPidFor(harness: string, paneId: string): string {
		switch (harness) {
			case "opencode": return ocSubscriberPidFile(paneId, opts.sessionKey);
			case "claude":   return ccSubscriberPidFile(paneId, opts.sessionKey);
			case "pi":       return piSubscriberPidFile(paneId, opts.sessionKey);
			case "codex":    return cxSubscriberPidFile(paneId, opts.sessionKey);
			default: return "";
		}
	}

	// Round-4 #10: in-memory subscriber pid → alive check. Falls back
	// to reading the pid file on cache miss (max-lifetime successor
	// inherits the same pid files; the cache populates fresh on its
	// first spawn cycle).
	function subscriberAlive(paneId: string, pidFile: string): boolean {
		let pid = subscriberPid.get(paneId);
		if (pid === undefined) {
			if (!pidFile) return false;
			try {
				if (!existsSync(pidFile)) return false;
				const txt = readFileSync(pidFile, "utf8").trim();
				if (!/^[1-9][0-9]*$/.test(txt)) return false;
				pid = Number.parseInt(txt, 10);
				subscriberPid.set(paneId, pid);
			} catch { return false; }
		}
		try { process.kill(pid, 0); return true; }
		catch (e) { return (e as NodeJS.ErrnoException).code === "EPERM"; }
	}

	function ocBellMarkerFile(paneId: string): string {
		return join(opts.stateDir, `oc-bell-${paneId.replace(/^%/, "")}`);
	}

	function touchOcBellMarker(paneId: string): void {
		const marker = ocBellMarkerFile(paneId);
		try { writeFileSync(marker, `${Date.now() * 1000000}\n`); }
		catch { /* */ }
	}

	while (true) {
		// vstack#59: reconcile tracked entries every N seconds.
		const nowReconcile = Math.floor(Date.now() / 1000);
		if (nowReconcile - lastReconcileEpoch >= reconcileIntervalSec) {
			lastReconcileEpoch = nowReconcile;
			reconcileNow("tick");
		}

		// Round-4 #9: gate heartbeat file mtime by heartbeatTicks. The
		// log line is already gated by the same counter; doing the file
		// touch on every tick wasted a syscall when no other change
		// occurred. Operators reading mtime get the same cadence as the
		// log lines.
		if (heartbeatCounter % opts.heartbeatTicks === 0) touchHeartbeat(heartbeatFile);

		if (opts.maxLifetime > 0) {
			const elapsed = Math.floor(Date.now() / 1000) - startEpoch;
			if (elapsed >= opts.maxLifetime) {
				log("max-lifetime", `elapsed=${elapsed}s >= MAX_LIFETIME=${opts.maxLifetime}s; spawn successor (TS option-A divergence from bash's exec-in-place)`);
				const handoff = liveInnerArgsForHandoff(opts.paneRegistryBin, {
					innerTargets: innerIds.slice(),
					innerHarnesses: innerIds.map((id) => paneHarness.get(id) ?? ""),
				});
				for (const message of handoff.warnings) warn("handoff-inner-live-warn", message);
				log("handoff-inner-live", `source=${handoff.source} panes=${handoff.innerTargets.length} inner=${handoff.innerTargets.join(",") || "(empty)"} harnesses=${handoff.innerHarnesses.join(",") || "(empty)"}`);
				const { maxLifetimeExec } = require("./lifecycle.ts") as typeof import("./lifecycle.ts");
				maxLifetimeExec({
					activity,
					scriptPath: opts.scriptPath,
					origArgs: opts.origArgs,
					logFile,
					handoffInnerTargets: handoff.innerTargets,
					handoffInnerHarnesses: handoff.innerHarnesses,
				});
			}
		}

		if (!sessionAlive(opts.sessionId)) {
			log("session-gone", `session_id=${opts.sessionId} gone; exiting`);
			setDaemonExitReason("session-gone");
			break;
		}

		paneCache.refresh();

		if (!paneCache.alive(masterId)) {
			log("master-gone", `master ${masterId} gone; exiting`);
			setDaemonExitReason("master-gone");
			// vstack#70: write a structured recovery hint before exit so
			// operators have a clear breadcrumb. Failure must not block exit.
			try {
				const hint = writeRecoveryHint({
					sessionId: opts.sessionId,
					sessionKey: opts.sessionKey,
					masterPaneId: masterId,
					masterPid: resolveMasterPidSafe(masterId),
					stateDir: opts.stateDir,
					eventsFile,
				});
				if (hint.ok) log("exit", `master-gone; recovery hint at ${hint.path}`);
				else log("exit-warn", `master-gone; recovery hint write failed (${hint.error}); expected at ${hint.path}`);
			} catch (err) {
				log("exit-warn", `master-gone; recovery hint write threw: ${(err as Error)?.message ?? err}; expected at ${recoveryHintPath(opts.stateDir, opts.sessionKey)}`);
			}
			break;
		}

		clearStaleWakePending({
			masterId, sessionLock, wakePending, busyFile,
			masterTurnTtl: opts.masterTurnTtl,
			wakePendingTtl: opts.wakePendingTtl,
			notifiedHash, lastEventKey, lastBellHash,
			log,
		});

		const now = Math.floor(Date.now() / 1000);
		const tickReasons: string[] = [];
		const tickPending: TickPending[] = [];
		const tickBellWins: string[] = [];
		const tickActivity: WakeEventRow[] = [];

		// 1) Drain adapter subscriber events. Round-4 #8: fast-path the
		// 'no wake-events log' case so we don't pay flock + bash + cat
		// per tick during steady-state with no subscribers active.
		let wakeDrain: ReturnType<typeof drainOcWakeEvents>;
		try {
			if (!existsSync(wakeEventsLog) || statSync(wakeEventsLog).size === 0) {
				wakeDrain = { lines: [], status: 0 };
			} else {
				wakeDrain = drainOcWakeEvents(sessionLock, wakeEventsLog);
			}
		} catch {
			wakeDrain = drainOcWakeEvents(sessionLock, wakeEventsLog);
		}
		for (const line of wakeDrain.lines) {
			let ev: WakeEventRow;
			try { ev = JSON.parse(line) as WakeEventRow; } catch { continue; }
			const evPid = typeof ev.pane_id === "string" ? ev.pane_id : "";
			const evHash = typeof ev.hash === "string" ? ev.hash : "";
			const evTag = typeof ev.classifier_tag === "string" ? ev.classifier_tag : "rendering";
			if (!evPid || !evHash) continue;
			if (!paneCache.alive(evPid)) continue;
			if (!firstSeen.has(evPid)) firstSeen.set(evPid, now);
			if (notifiedHash.get(evPid) === evHash) continue;

			let src = "adapter-event";
			if (evTag === "oc-question") src = "oc-question-event";
			else if (evTag === "pi-question") src = "pi-question-event";
			else if (evTag === "pi-subagent-completion") src = "pi-subagent-completion-event";
			else if (evTag === BG_TASK_EXIT_CLASSIFIER_TAG) src = "pi-bg-task-exit-event";

			if (isCanonicalTag(evTag)) {
				// vstack#69: respect notifyOnExit / notifyMode on bg-task-exit
				// events so engineer-scaffolding tasks (smoke tests, daemon
				// mocks) don't wake master. The event row is still appended to
				// WAKE_EVENTS_LOG by the subscriber for the dashboard.
				if (evTag === BG_TASK_EXIT_CLASSIFIER_TAG) {
					const bgDecision = shouldEmitBgTaskExitWake({ task: ev.task as any });
					if (!bgDecision.emit) {
						if (opts.verbose) log("bg-task-drop", `${evPid} reason=${bgDecision.reason}`);
						notifiedHash.set(evPid, evHash);
						continue;
					}
				}
				let extraJson = "null";
				if (evTag === "oc-question" || evTag === "pi-question") {
					extraJson = JSON.stringify({ event_type: ev.event_type, request_id: ev.request_id, question: ev.question, harness: ev.harness });
				} else if (evTag === "pi-subagent-completion") {
					extraJson = JSON.stringify({ event_type: ev.event_type, completion: ev.completion, harness: ev.harness });
				} else if (evTag === BG_TASK_EXIT_CLASSIFIER_TAG) {
					extraJson = JSON.stringify({ event_type: ev.event_type, harness: ev.harness, sequence: ev.sequence, task: ev.task });
				}
				// Round-4 #6: only record a wake reason when the event is
				// actually durable. appendEvent returns false on dedup (no
				// wake needed) or on append failure (don't wake without a
				// matching event — master would ack and find nothing).
				const appended = appendEvent({
					paneId: evPid, hash: evHash, tag: evTag, reason: src,
					ageSec: 0, isBell: false, extraJson,
					sessionLock, eventsFile, wakePending, lastEventKey,
				});
				if (appended) {
					log("classify", `${evPid} ${src} tag=${evTag} (canonical)`);
					tickActivity.push(ev);
					tickReasons.push(`adapter:${evPid}:${evTag}`);
					tickPending.push({ paneId: evPid, hash: evHash, tag: evTag, isBell: false });
				}
			} else {
				emitActivityForWakeRow(activity, ev);
				if (opts.verbose) log("classify", `${evPid} ${src} tag=${evTag} (non-canonical)`);
				notifiedHash.set(evPid, evHash);
			}
		}

		// 2) Per-inner-pane bell / hash-change / stable-age branches.
		for (const innerId of innerIds) {
			if (!paneCache.alive(innerId)) {
				const lastGone = lastGoneLog.get(innerId) ?? 0;
				if (lastGone === 0) {
					// vstack#58: first pane-gone observation reaps the orphaned
					// subscriber so its bash sleep loop and pid/log files don't
					// accumulate across long sessions. Subsequent ticks keep the
					// 30s log-only cadence.
					log("pane-gone", `${innerId} no longer exists; reaping subscriber`);
					if (ocSubscribed.has(innerId) || subscriberPid.has(innerId)) {
						reapSubscriberForPane(innerId, "pane-gone");
					}
					lastGoneLog.set(innerId, now);
				} else if (now - lastGone > 30) {
					log("pane-gone", `${innerId} no longer exists; skipping`);
					lastGoneLog.set(innerId, now);
				}
				continue;
			}

			if (ocSubscribed.has(innerId)) {
				const subHarness = paneHarness.get(innerId) ?? opts.defaultHarness;
				const pidFile = subscriberPidFor(subHarness, innerId);
				if (subscriberAlive(innerId, pidFile)) {
					if (subHarness === "opencode" && paneCache.bell(innerId) === 1) {
						touchOcBellMarker(innerId);
						const winId = paneCache.windowId(innerId);
						if (winId) clearBellForWindow(opts.sessionId, winId);
					}
					continue;
				}
				const deadPid = subscriberPid.get(innerId);
				log("subscriber-dead", `pane=${innerId} harness=${subHarness}; clearing OC_SUBSCRIBED and falling back to capture-pane`);
				emitSubscriberDead(activity, subHarness, innerId, deadPid);
				ocSubscribed.delete(innerId);
				subscriberPid.delete(innerId);
				try { unlinkSync(pidFile); } catch { /* */ }
			}

			if (!firstSeen.has(innerId)) firstSeen.set(innerId, now);
			const paneAge = now - (firstSeen.get(innerId) ?? now);
			const inGrace = paneAge < opts.graceSec;

			const target = paneCache.target(innerId);
			if (!target) continue;
			const winId = paneCache.windowId(innerId);
			const harness = paneHarness.get(innerId) ?? opts.defaultHarness;
			const bell = paneCache.bell(innerId);
			const paneActivity = paneCache.activity(innerId);

			// Round-4 #11: skip capture-pane subprocess on inactive
			// panes. Activity = 0 + bell = 0 + cached hash present means
			// nothing changed since the last capture; reuse the prevHash
			// for the stable-age check. Low-frequency sweep every 30
			// ticks runs a full capture anyway so missed signals (rare,
			// e.g. tmux activity flag reset by another consumer) are
			// caught within ~60s at default poll. The bash daemon does
			// not do this skip — TS-only optimization.
			const sweepNow = captureSweepCounter >= 30;
			const prevActivity = lastActivityFlag.get(innerId) ?? -1;
			const prevHashEntry = lastHash.get(innerId);
			const canSkipCapture = !sweepNow && bell === 0 && paneActivity === 0 && prevActivity === 0 && prevHashEntry !== undefined;
			lastActivityFlag.set(innerId, paneActivity);
			const buf = canSkipCapture ? "" : capturePane(target, opts.captureLines);
			const hash = canSkipCapture ? prevHashEntry! : captureHash12(buf);
			const stab = stabilityForHarness(harness, opts.stabilitySec);

			if (opts.debugPane && opts.debugPane === innerId) {
				const dbgTag = classifyBuffer(buf, { classifierBin: opts.classifierBin });
				log("debug-pane", `${innerId} harness=${harness} bell=${bell} hash=${hash} stable=${stab} tag=${dbgTag} in_grace=${inGrace ? 1 : 0} pane_age=${paneAge}s`);
			}

			const prevHash = lastHash.get(innerId) ?? "";
			const prevSince = hashSince.get(innerId) ?? 0;

			if (bell === 1 && inGrace) {
				log("grace-skip", `${innerId} bell suppressed during cold-start grace (age=${paneAge}s < ${opts.graceSec}s)`);
				continue;
			}
			if (bell === 1 && lastBellHash.get(innerId) !== hash) {
				touchOcBellMarker(innerId);
				const tag = classifyBuffer(buf, { classifierBin: opts.classifierBin });
				// vstack#68: filter bell wakes. Non-canonical tags drop entirely
				// (a plain BEL with no prompt visible is terminal noise);
				// canonical tags are rate-limited per pane to suppress storms
				// during normal agent iteration.
				const bellDecision = shouldEmitBellWake(bellWakeState, {
					paneId: innerId,
					tag,
					isCanonical: isCanonicalTag(tag),
					intervalSec: bellWakeIntervalSec,
					nowSec: now,
				});
				if (!bellDecision.emit) {
					if (opts.verbose) log("bell-drop", `${innerId} tag=${tag} reason=${bellDecision.reason}`);
					lastHash.set(innerId, hash);
					hashSince.set(innerId, now);
					lastBellHash.set(innerId, hash);
					if (winId) clearBellForWindow(opts.sessionId, winId);
					continue;
				}
				// Round-4 #6: gate wake-reason recording on append success.
				const appended = appendEvent({
					paneId: innerId, hash, tag, reason: "bell",
					ageSec: 0, isBell: true,
					sessionLock, eventsFile, wakePending, lastEventKey,
				});
				if (appended) {
					recordBellWake(bellWakeState, innerId, tag, now);
					tickActivity.push({ classifier_tag: tag, event_type: tag, hash, harness, pane_id: innerId });
					tickReasons.push(`bell:${innerId}:${tag}`);
					tickPending.push({ paneId: innerId, hash, tag, isBell: true });
					if (winId) tickBellWins.push(winId);
				}
				lastHash.set(innerId, hash);
				hashSince.set(innerId, now);
				continue;
			}

			if (hash !== prevHash) {
				lastHash.set(innerId, hash);
				hashSince.set(innerId, now);
				if (opts.verbose) log("hash-change", `${innerId} ${prevHash} -> ${hash}`);
				continue;
			}

			const age = now - prevSince;
			if (age >= stab && notifiedHash.get(innerId) !== hash) {
				const tag = classifyBuffer(buf, { classifierBin: opts.classifierBin });
				if (inGrace && isCanonicalTag(tag)) {
					log("grace-skip", `${innerId} stable wake suppressed; tag=${tag} age=${age}s pane_age=${paneAge}s < ${opts.graceSec}s`);
					notifiedHash.set(innerId, hash);
					continue;
				}
				if (isCanonicalTag(tag)) {
					// Round-4 #6: gate wake-reason recording on append success.
					const appended = appendEvent({
						paneId: innerId, hash, tag, reason: "stable",
						ageSec: age, isBell: false,
						sessionLock, eventsFile, wakePending, lastEventKey,
					});
					if (appended) {
						log("classify", `${innerId} age=${age}s tag=${tag} (canonical)`);
						tickActivity.push({ classifier_tag: tag, event_type: tag, hash, harness, pane_id: innerId });
						tickReasons.push(`stable:${innerId}:${tag}(${age}s)`);
						tickPending.push({ paneId: innerId, hash, tag, isBell: false });
					}
				} else {
					if (opts.verbose) log("classify", `${innerId} age=${age}s tag=${tag} (non-canonical)`);
					notifiedHash.set(innerId, hash);
				}
			}
		}

		// 3) Heartbeat log line cadence.
		captureSweepCounter = sweepResetNeeded(captureSweepCounter);
		heartbeatCounter += 1;
		if (heartbeatCounter >= opts.heartbeatTicks) {
			heartbeatCounter = 0;
			let alive = 0;
			for (const id of innerIds) if (paneCache.alive(id)) alive += 1;
			const wpState = existsSync(wakePending) ? "in-flight" : "absent";
			const bfState = existsSync(busyFile) ? "held" : "unlocked";
			let ownerMemFields = "";
			if (ownerCgroupProbeOn) {
				try {
					const masterPid = resolveMasterPidSafe(masterId);
					if (masterPid) {
						const snapshot = probeOwnerCgroupMem(masterPid);
						const fields = ownerMemHeartbeatFields(snapshot);
						if (fields) ownerMemFields = ` ${fields}`;
					}
				} catch { /* observability-only; never block heartbeat */ }
			}
			log("heartbeat", `panes=${innerIds.length} alive=${alive} wake_pending=${wpState} busy_lock=${bfState}${ownerMemFields}`);
		}

		// 4) Wake delivery + post-success state updates.
		if (tickReasons.length > 0) {
			const combined = tickReasons.join("|");
			const inFlightJson = JSON.stringify(tickPending.map((p) => ({ pane_id: p.paneId, hash: p.hash, tag: p.tag, is_bell: p.isBell })));
			const ok = wakeMaster({
				activity,
				masterId, masterHarness, sessionKey: opts.sessionKey,
				sessionLock, wakePending, busyFile,
				masterTurnTtl: opts.masterTurnTtl,
				daemonPid: process.pid,
				combined, inFlightJson,
				log,
				isMasterBusy: () => isMasterBusy({ busyFile, masterId, masterTurnTtl: opts.masterTurnTtl }),
				paneTargetFor: (pid) => paneCache.target(pid),
			});
			for (const row of tickActivity) emitActivityForWakeRow(activity, row);
			if (ok) {
				for (const p of tickPending) {
					notifiedHash.set(p.paneId, p.hash);
					if (p.isBell) {
						lastBellHash.set(p.paneId, p.hash);
						touchOcBellMarker(p.paneId);
					}
				}
				for (const w of tickBellWins) {
					if (w) clearBellForWindow(opts.sessionId, w);
				}
			}
		}

		await new Promise((res) => setTimeout(res, opts.pollSec * 1000));
	}
}

function sweepResetNeeded(n: number): number {
	return n >= 30 ? 0 : n + 1;
}

function emitSubscriberLifecycle(ctx: DaemonActivityContext, reattached: boolean, harness: string, paneId: string, pid: number): void {
	if (reattached) emitSubscriberReattached(ctx, harness, paneId, pid);
	else emitSubscriberStarted(ctx, harness, paneId, pid);
}
