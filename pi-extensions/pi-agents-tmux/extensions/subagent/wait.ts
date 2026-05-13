export interface BridgeStateSnapshot {
	isIdle?: boolean;
	[key: string]: unknown;
}

export interface IdleTransitionResult {
	lastState?: BridgeStateSnapshot;
	samples: number;
	status: "idle-after-busy" | "never-busy" | "timeout";
	timedOut: boolean;
	transitioned: boolean;
}

export function extractBridgeState(stdout: string): BridgeStateSnapshot | undefined {
	if (!stdout.trim()) return undefined;
	try {
		const parsed = JSON.parse(stdout);
		const data = parsed?.data && typeof parsed.data === "object" ? parsed.data : parsed;
		return data && typeof data === "object" && !Array.isArray(data) ? data as BridgeStateSnapshot : undefined;
	} catch {
		return undefined;
	}
}

export async function waitForIdleTransition(
	readState: () => Promise<BridgeStateSnapshot | undefined>,
	timeoutMs = 30_000,
	pollMs = 500,
): Promise<IdleTransitionResult> {
	const deadline = Date.now() + Math.max(0, Math.floor(timeoutMs));
	const interval = Math.max(50, Math.floor(pollMs));
	let observedBusy = false;
	let samples = 0;
	let lastState: BridgeStateSnapshot | undefined;
	while (true) {
		lastState = await readState();
		samples += 1;
		const currentIdle = lastState?.isIdle === true;
		if (currentIdle && observedBusy) {
			return { lastState, samples, status: "idle-after-busy", timedOut: false, transitioned: true };
		}
		if (lastState?.isIdle === false) observedBusy = true;
		if (Date.now() >= deadline) {
			return { lastState, samples, status: observedBusy ? "timeout" : "never-busy", timedOut: true, transitioned: false };
		}
		await new Promise((resolve) => setTimeout(resolve, Math.min(interval, Math.max(0, deadline - Date.now()))));
	}
}
