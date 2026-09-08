export type PiActivitySource = "pi-session" | "pi-agents" | "pi-bg-task" | "pi-questions";
export type PiActivitySeverity = "debug" | "info" | "success" | "warning" | "error";
export type PiActivityImportance = "critical" | "important" | "normal" | "noisy";

export interface PiActivityEvent {
	type: string;
	source: PiActivitySource;
	severity: PiActivitySeverity;
	importance: PiActivityImportance;
	summary: string;
	body?: string;
	refs?: { task_id?: string; bg_task_id?: string; question_id?: string; agent?: string };
	details?: Record<string, unknown>;
	ts?: string;
}

export interface PiActivityBroker {
	publish(event: PiActivityEvent): void;
	subscribe(listener: (event: PiActivityEvent) => void): () => void;
	recent(limit?: number): PiActivityEvent[];
}

type BridgePublisher = (event: PiActivityEvent) => void;

interface InternalActivityBroker extends PiActivityBroker {
	_bridgePublishers: Map<string, BridgePublisher>;
	_events: PiActivityEvent[];
	_listeners: Set<(event: PiActivityEvent) => void>;
}

const ACTIVITY_BROKER_SYMBOL = Symbol.for("kendex.pi.activity");
const DEFAULT_RECENT_LIMIT = 100;
const warnedBridgePublisherFailures = new Set<string>();

export function getPiActivityBroker(): PiActivityBroker {
	return ensureActivityBroker();
}

export function publishPiActivity(event: PiActivityEvent): void {
	try {
		ensureActivityBroker().publish(event);
	} catch {
		// Broker publication is best-effort; producers must never fail because activity failed.
	}
}

export function installPiActivityBridgePublisher(key: string, publisher: BridgePublisher): () => void {
	const broker = ensureActivityBroker();
	broker._bridgePublishers.set(key, publisher);
	return () => {
		const current = ensureActivityBroker();
		if (current._bridgePublishers.get(key) === publisher) current._bridgePublishers.delete(key);
	};
}

function ensureActivityBroker(): InternalActivityBroker {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const existing = host[ACTIVITY_BROKER_SYMBOL];
	if (isInternalBroker(existing)) return existing;

	const listeners = new Set<(event: PiActivityEvent) => void>();
	const events: PiActivityEvent[] = [];
	const bridgePublishers = new Map<string, BridgePublisher>();
	const broker: InternalActivityBroker = {
		_bridgePublishers: bridgePublishers,
		_events: events,
		_listeners: listeners,
		publish(input: PiActivityEvent): void {
			try {
				const event = normalizeActivityEvent(input);
				events.push(event);
				if (events.length > DEFAULT_RECENT_LIMIT) events.splice(0, events.length - DEFAULT_RECENT_LIMIT);
				for (const listener of [...listeners]) {
					try { listener(event); } catch { /* listener failures are isolated */ }
				}
				for (const publisher of [...bridgePublishers.values()]) {
					try { publisher(event); } catch (error) { warnBridgePublisherFailure(event, error); }
				}
			} catch {
				// Invalid producer payloads are ignored; broker contract is fail-open.
			}
		},
		recent(limit = DEFAULT_RECENT_LIMIT): PiActivityEvent[] {
			const safeLimit = Math.max(0, Math.floor(Number.isFinite(limit) ? limit : DEFAULT_RECENT_LIMIT));
			return events.filter(isRecentActivityEvent).slice(-safeLimit).reverse();
		},
		subscribe(listener: (event: PiActivityEvent) => void): () => void {
			listeners.add(listener);
			return () => { listeners.delete(listener); };
		},
	};
	host[ACTIVITY_BROKER_SYMBOL] = broker;
	return broker;
}

function isInternalBroker(value: unknown): value is InternalActivityBroker {
	return Boolean(value)
		&& typeof value === "object"
		&& typeof (value as PiActivityBroker).publish === "function"
		&& typeof (value as PiActivityBroker).subscribe === "function"
		&& typeof (value as PiActivityBroker).recent === "function"
		&& (value as Partial<InternalActivityBroker>)._bridgePublishers instanceof Map
		&& Array.isArray((value as Partial<InternalActivityBroker>)._events)
		&& (value as Partial<InternalActivityBroker>)._listeners instanceof Set;
}

function normalizeActivityEvent(input: PiActivityEvent): PiActivityEvent {
	if (!input || typeof input !== "object") throw new Error("activity event must be an object");
	const type = requiredString(input.type, "type");
	const source = normalizeSource(input.source);
	const severity = normalizeSeverity(input.severity);
	const importance = normalizeImportance(input.importance);
	const summary = requiredString(input.summary, "summary");
	const ts = typeof input.ts === "string" && input.ts.trim() ? input.ts : new Date().toISOString();
	return {
		type,
		source,
		severity,
		importance,
		summary,
		...(typeof input.body === "string" && input.body ? { body: input.body } : {}),
		...(input.refs && typeof input.refs === "object" ? { refs: sanitizeStringRecord(input.refs) as PiActivityEvent["refs"] } : {}),
		...(input.details && typeof input.details === "object" && !Array.isArray(input.details) ? { details: input.details } : {}),
		ts,
	};
}

function requiredString(value: unknown, field: string): string {
	if (typeof value !== "string" || value.trim().length === 0) throw new Error(`activity ${field} is required`);
	return value.trim();
}

function normalizeSource(value: unknown): PiActivitySource {
	if (value === "pi-session" || value === "pi-agents" || value === "pi-bg-task" || value === "pi-questions") return value;
	throw new Error(`invalid activity source: ${String(value)}`);
}

function normalizeSeverity(value: unknown): PiActivitySeverity {
	if (value === "debug" || value === "info" || value === "success" || value === "warning" || value === "error") return value;
	throw new Error(`invalid activity severity: ${String(value)}`);
}

function normalizeImportance(value: unknown): PiActivityImportance {
	if (value === "critical" || value === "important" || value === "normal" || value === "noisy") return value;
	throw new Error(`invalid activity importance: ${String(value)}`);
}

function sanitizeStringRecord(input: Record<string, unknown>): Record<string, string> {
	const out: Record<string, string> = {};
	for (const [key, value] of Object.entries(input)) {
		if (typeof value === "string" && value.trim()) out[key] = value.trim();
	}
	return out;
}

function isRecentActivityEvent(value: unknown): value is PiActivityEvent {
	try {
		normalizeActivityEvent(value as PiActivityEvent);
		return true;
	} catch {
		return false;
	}
}

function warnBridgePublisherFailure(event: PiActivityEvent, error: unknown): void {
	const errorName = error instanceof Error && error.name ? error.name : typeof error;
	const key = `bridge-publisher\0${event.type}\0${errorName}`;
	if (warnedBridgePublisherFailures.has(key)) return;
	warnedBridgePublisherFailures.add(key);
	const message = error instanceof Error ? error.message : String(error);
	console.warn(`publisher_failure=${event.type} source=${event.source} error=${errorName}\nActivity bridge publisher failed: ${message}`);
}
