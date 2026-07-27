export type PiActivitySeverity = "debug" | "info" | "success" | "warning" | "error";
export type PiActivityImportance = "critical" | "important" | "normal" | "noisy";

export interface PiActivityEvent {
	type: string;
	source: "pi-questions";
	severity: PiActivitySeverity;
	importance: PiActivityImportance;
	summary: string;
	body?: string;
	refs?: { question_id?: string };
	details?: Record<string, unknown>;
	ts?: string;
}

export interface QuestionActivityEvent {
	action: "opened" | "answered" | "rejected";
	requestId: string;
	openedAt: string;
	closedAt?: string;
	source?: string;
	request?: {
		header?: string;
		questions?: Array<{ header?: string; question?: string; options?: Array<{ label?: string; description?: string }> }>;
	};
	result?: { answers?: string[][]; cancelled?: true; error?: string; requestId?: string };
}

interface PiActivityBroker {
	publish(event: PiActivityEvent): void;
}

const ACTIVITY_BROKER_SYMBOL = Symbol.for("vstack.pi.activity");

export function publishQuestionActivity(event: QuestionActivityEvent): void {
	try {
		const broker = activityBroker();
		if (!broker) return;
		broker.publish(buildQuestionActivity(event));
	} catch {
		// Activity publication is best-effort and must never affect question lifecycle.
	}
}

export function publishQuestionDebug(summary: string): void {
	try {
		activityBroker()?.publish({
			importance: "noisy",
			severity: "debug",
			source: "pi-questions",
			summary,
			type: "question.debug",
		});
	} catch {
		// Debug breadcrumbs are best-effort and must never affect question lifecycle.
	}
}

export function buildQuestionActivity(event: QuestionActivityEvent): PiActivityEvent {
	const header = event.request?.header || event.request?.questions?.[0]?.header || "Question";
	const type = event.action === "opened" ? "question.opened" : event.action === "answered" ? "question.answered" : "question.rejected";
	return {
		details: {
			action: event.action,
			answer: selectedAnswer(event),
			closed_at: event.closedAt,
			header,
			opened_at: event.openedAt,
			option: selectedOption(event),
			question_count: event.request?.questions?.length ?? null,
			source: event.source,
		},
		importance: event.action === "opened" ? "important" : "normal",
		refs: { question_id: event.requestId },
		severity: event.action === "rejected" ? "warning" : event.action === "answered" ? "success" : "warning",
		source: "pi-questions",
		summary: summaryFor(type, event.requestId, header),
		ts: event.closedAt ?? event.openedAt,
		type,
	};
}

function activityBroker(): PiActivityBroker | undefined {
	const broker = (globalThis as unknown as Record<PropertyKey, unknown>)[ACTIVITY_BROKER_SYMBOL];
	return broker && typeof broker === "object" && typeof (broker as PiActivityBroker).publish === "function"
		? broker as PiActivityBroker
		: undefined;
}

function summaryFor(type: string, requestId: string, header: string): string {
	if (type === "question.answered") return `question answered: ${requestId}`;
	if (type === "question.rejected") return `question rejected: ${requestId}`;
	return `question opened: ${header || requestId}`;
}

function selectedAnswer(event: QuestionActivityEvent): string[] | null {
	const answers = event.result?.answers;
	if (!Array.isArray(answers) || answers.length === 0) return null;
	return answers.flat().filter((value): value is string => typeof value === "string" && value.trim().length > 0);
}

function selectedOption(event: QuestionActivityEvent): string | null {
	const answer = selectedAnswer(event)?.[0];
	if (!answer) return null;
	return answer;
}
