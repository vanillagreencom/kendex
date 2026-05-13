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
import { clearStaleWakePending, isMasterBusy } from "./busy.ts";
import { clearBellForWindow, wakeMaster, resolvePiMasterPid } from "./wake.ts";
import { PaneCache, capturePane, captureHash12, classifyBuffer, resolvePaneId, sessionAlive, stabilityForHarness } from "./pane-meta.ts";
import { daemonLog, daemonWarn } from "./log.ts";
import { touchHeartbeat } from "./lifecycle.ts";
import { drainOcWakeEvents } from "./subscribers/drain.ts";
import {
	spawnOcSubscriber,
	spawnCcSubscriber,
	spawnPiSubscriber,
	spawnCxSubscriber,
} from "./subscribers/spawn.ts";
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
	scriptPath: string;
	origArgs: string[];
	paneRegistryBin: string;    // path to pane-registry executable for resolve_*_meta
}

interface TickPending {
	paneId: string;
	hash: string;
	tag: string;
	isBell: boolean;
}

function paneRegistryArgs(bin: string, action: string, issue: string): string {
	const r = spawnSync(bin, [action, issue], { encoding: "utf8" });
	if (r.status !== 0) return "";
	return (r.stdout ?? "").trim();
}

function paneRegistryIssueForPane(bin: string, paneTarget: string): string {
	const r = spawnSync(bin, ["find-by-pane", paneTarget], { encoding: "utf8" });
	if (r.status !== 0) return "";
	const raw = (r.stdout ?? "").trim();
	if (!raw.startsWith("{")) return raw;
	try {
		const parsed = JSON.parse(raw) as { id?: unknown };
		return typeof parsed.id === "string" ? parsed.id : "";
	} catch {
		return "";
	}
}

function extractFlag(args: string, flag: string): string {
	const tokens = args.split(/\s+/);
	for (let i = 0; i < tokens.length - 1; i += 1) {
		if (tokens[i] === flag) return tokens[i + 1] ?? "";
	}
	return "";
}

function resolveMeta(bin: string, action: string, paneTarget: string): string {
	const issue = paneRegistryIssueForPane(bin, paneTarget);
	if (!issue) return "";
	return paneRegistryArgs(bin, action, issue);
}

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
	const innerIds: string[] = [];
	const seenInner = new Set<string>();
	for (let i = 0; i < opts.innerTargets.length; i += 1) {
		const t = opts.innerTargets[i]!;
		const id = resolvePaneId(t);
		if (!id) {
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
	for (const id of innerIds) {
		const h = paneHarness.get(id) ?? "";
		const target = ocPaneTarget.get(id) ?? "";
		switch (h) {
			case "opencode": {
				const meta = resolveMeta(opts.paneRegistryBin, "oc-attach-args", target);
				const url = extractFlag(meta, "--url");
				const sid = extractFlag(meta, "--session");
				if (url && sid) {
					const { pid } = spawnOcSubscriber({ ...baseEnv, sessionKey: opts.sessionKey, paneId: id, ocUrl: url, sessionId: sid, ocLastAssistantJq: OC_LAST_ASSISTANT_JQ, log });
					ocSubscribed.set(id, true);
					subscriberPid.set(id, pid);
				}
				break;
			}
			case "claude": {
				const meta = resolveMeta(opts.paneRegistryBin, "cc-channel-args", target);
				const transcript = extractFlag(meta, "--transcript");
				if (transcript) {
					const { pid } = spawnCcSubscriber({ ...baseEnv, sessionKey: opts.sessionKey, paneId: id, transcript, ccLastAssistantJq: CC_LAST_ASSISTANT_JQ, log });
					ocSubscribed.set(id, true);
					subscriberPid.set(id, pid);
				}
				break;
			}
			case "pi": {
				const meta = resolveMeta(opts.paneRegistryBin, "pi-bridge-args", target);
				const piPid = extractFlag(meta, "--pid");
				const piSocket = extractFlag(meta, "--socket");
				if (piPid || piSocket) {
					const { pid } = spawnPiSubscriber({ ...baseEnv, sessionKey: opts.sessionKey, paneId: id, piPid, piSocket, piLastAssistantJq: PI_LAST_ASSISTANT_JQ, log });
					ocSubscribed.set(id, true);
					subscriberPid.set(id, pid);
				}
				break;
			}
			case "codex": {
				const meta = resolveMeta(opts.paneRegistryBin, "cx-bridge-args", target);
				const cxUrl = extractFlag(meta, "--url");
				const threadId = extractFlag(meta, "--thread");
				if (cxUrl && threadId) {
					const { pid } = spawnCxSubscriber({ ...baseEnv, sessionKey: opts.sessionKey, paneId: id, cxUrl, threadId, cxLastAssistantJq: CX_LAST_ASSISTANT_JQ, log });
					ocSubscribed.set(id, true);
					subscriberPid.set(id, pid);
				}
				break;
			}
		}
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
				const { maxLifetimeExec } = require("./lifecycle.ts") as typeof import("./lifecycle.ts");
				maxLifetimeExec({ scriptPath: opts.scriptPath, origArgs: opts.origArgs, logFile });
			}
		}

		if (!sessionAlive(opts.sessionId)) {
			log("session-gone", `session_id=${opts.sessionId} gone; exiting`);
			break;
		}

		paneCache.refresh();

		if (!paneCache.alive(masterId)) {
			log("master-gone", `master ${masterId} gone; exiting`);
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
			let ev: { pane_id?: string; hash?: string; classifier_tag?: string; event_type?: string; request_id?: string; question?: unknown; harness?: string; completion?: unknown; task?: unknown };
			try { ev = JSON.parse(line); } catch { continue; }
			const evPid = ev.pane_id ?? "";
			const evHash = ev.hash ?? "";
			const evTag = ev.classifier_tag ?? "rendering";
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
				let extraJson = "null";
				if (evTag === "oc-question" || evTag === "pi-question") {
					extraJson = JSON.stringify({ event_type: ev.event_type, request_id: ev.request_id, question: ev.question, harness: ev.harness });
				} else if (evTag === "pi-subagent-completion") {
					extraJson = JSON.stringify({ event_type: ev.event_type, completion: ev.completion, harness: ev.harness });
				} else if (evTag === BG_TASK_EXIT_CLASSIFIER_TAG) {
					extraJson = JSON.stringify({ event_type: ev.event_type, task: ev.task, harness: ev.harness });
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
					tickReasons.push(`adapter:${evPid}:${evTag}`);
					tickPending.push({ paneId: evPid, hash: evHash, tag: evTag, isBell: false });
				}
			} else {
				if (opts.verbose) log("classify", `${evPid} ${src} tag=${evTag} (non-canonical)`);
				notifiedHash.set(evPid, evHash);
			}
		}

		// 2) Per-inner-pane bell / hash-change / stable-age branches.
		for (const innerId of innerIds) {
			if (!paneCache.alive(innerId)) {
				const lastGone = lastGoneLog.get(innerId) ?? 0;
				if (now - lastGone > 30) {
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
			log("subscriber-dead", `pane=${innerId} harness=${subHarness}; clearing OC_SUBSCRIBED and falling back to capture-pane`);
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
			const activity = paneCache.activity(innerId);

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
			const canSkipCapture = !sweepNow && bell === 0 && activity === 0 && prevActivity === 0 && prevHashEntry !== undefined;
			lastActivityFlag.set(innerId, activity);
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
				// Round-4 #6: gate wake-reason recording on append success.
				const appended = appendEvent({
					paneId: innerId, hash, tag, reason: "bell",
					ageSec: 0, isBell: true,
					sessionLock, eventsFile, wakePending, lastEventKey,
				});
				if (appended) {
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
			log("heartbeat", `panes=${innerIds.length} alive=${alive} wake_pending=${wpState} busy_lock=${bfState}`);
		}

		// 4) Wake delivery + post-success state updates.
		if (tickReasons.length > 0) {
			const combined = tickReasons.join("|");
			const inFlightJson = JSON.stringify(tickPending.map((p) => ({ pane_id: p.paneId, hash: p.hash, tag: p.tag, is_bell: p.isBell })));
			const ok = wakeMaster({
				masterId, masterHarness, sessionKey: opts.sessionKey,
				sessionLock, wakePending, busyFile,
				masterTurnTtl: opts.masterTurnTtl,
				daemonPid: process.pid,
				combined, inFlightJson,
				log,
				isMasterBusy: () => isMasterBusy({ busyFile, masterId, masterTurnTtl: opts.masterTurnTtl }),
				paneTargetFor: (pid) => paneCache.target(pid),
			});
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
