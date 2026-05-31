import { appendEvent } from "./events.ts";
import {
	BUSY_STALL_CLASSIFIER_TAG,
	BusyStallWatchdog,
	sampleProcessTree,
	type BridgeProbeResult,
} from "./busy-stall-watchdog.ts";
import type { WakeEventRow } from "./activity.ts";

interface BusyStallTickPending {
	paneId: string;
	hash: string;
	tag: string;
	isBell: boolean;
}

export interface BusyStallEmitInput {
	watchdog: BusyStallWatchdog;
	harness: string;
	paneId: string;
	panePid: number | null;
	progressHash: string;
	gitHead: string;
	nowMs: number;
	bridgeProbe: () => BridgeProbeResult;
	sessionLock: string;
	eventsFile: string;
	wakePending: string;
	lastEventKey: Map<string, true>;
	log: (tag: string, message: string) => void;
	tickActivity: WakeEventRow[];
	tickReasons: string[];
	tickPending: BusyStallTickPending[];
}

export function emitBusyStallIfNeeded(input: BusyStallEmitInput): boolean {
	const candidate = input.watchdog.observeLocal({
		harness: input.harness,
		nowMs: input.nowMs,
		paneId: input.paneId,
		panePid: input.panePid,
		processSample: sampleProcessTree(input.panePid),
		progressKey: `${input.progressHash}|git:${input.gitHead}`,
	});
	if (!candidate) return false;

	const decision = input.watchdog.confirmBridge(candidate, input.bridgeProbe(), input.nowMs);
	if (!decision) return false;

	const extraJson = JSON.stringify({ event_type: "busy_stall", ...decision.details });
	const appended = appendEvent({
		ageSec: Number(decision.details.no_progress_sec ?? 0),
		extraJson,
		hash: decision.hash,
		isBell: false,
		paneId: input.paneId,
		reason: "busy-stall",
		sessionLock: input.sessionLock,
		tag: BUSY_STALL_CLASSIFIER_TAG,
		eventsFile: input.eventsFile,
		wakePending: input.wakePending,
		lastEventKey: input.lastEventKey,
	});
	if (!appended) return false;

	input.watchdog.markReported(decision);
	input.log("busy-stall", `pane=${input.paneId} hash=${decision.hash} details=${extraJson}`);
	input.tickActivity.push({
		classifier_tag: BUSY_STALL_CLASSIFIER_TAG,
		details: decision.details,
		event_type: "busy_stall",
		harness: input.harness,
		hash: decision.hash,
		pane_id: input.paneId,
	});
	input.tickReasons.push(`watchdog:${input.paneId}:${BUSY_STALL_CLASSIFIER_TAG}`);
	input.tickPending.push({ paneId: input.paneId, hash: decision.hash, tag: BUSY_STALL_CLASSIFIER_TAG, isBell: false });
	return true;
}
