import { beforeEach, describe, expect, test } from "bun:test";

import { buildQuestionActivity, publishQuestionActivity, publishQuestionDebug, type PiActivityEvent, type QuestionActivityEvent } from "../activity.js";

const BROKER_SYMBOL = Symbol.for("vstack.pi.activity");

function questionEvent(overrides: Partial<QuestionActivityEvent> = {}): QuestionActivityEvent {
	return {
		action: "opened",
		openedAt: "2026-05-16T00:00:00.000Z",
		request: {
			header: "Pick path",
			questions: [{ header: "Path", options: [{ label: "A" }, { label: "B" }], question: "Which path?" }],
		},
		requestId: "que_1",
		source: "tool",
		...overrides,
	};
}

function installBroker(): PiActivityEvent[] {
	const events: PiActivityEvent[] = [];
	(globalThis as unknown as Record<PropertyKey, unknown>)[BROKER_SYMBOL] = {
		publish(event: PiActivityEvent) { events.push(event); },
	};
	return events;
}

beforeEach(() => {
	delete (globalThis as unknown as Record<PropertyKey, unknown>)[BROKER_SYMBOL];
});

describe("question activity", () => {
	test("question.opened publishes with request id and header", () => {
		const events = installBroker();
		publishQuestionActivity(questionEvent());
		expect(events[0]).toMatchObject({
			importance: "important",
			refs: { question_id: "que_1" },
			severity: "warning",
			source: "pi-questions",
			summary: "question opened: Pick path",
			type: "question.opened",
		});
		expect(events[0]?.details).toMatchObject({ header: "Pick path", question_count: 1, source: "tool" });
	});

	test("question.answered includes selected option", () => {
		const event = buildQuestionActivity(questionEvent({
			action: "answered",
			closedAt: "2026-05-16T00:00:05.000Z",
			result: { answers: [["B"]], requestId: "que_1" },
		}));
		expect(event).toMatchObject({ importance: "normal", severity: "success", type: "question.answered" });
		expect(event.details).toMatchObject({ answer: ["B"], option: "B" });
		expect(event.ts).toBe("2026-05-16T00:00:05.000Z");
	});

	test("question.rejected maps to warning", () => {
		const event = buildQuestionActivity(questionEvent({
			action: "rejected",
			closedAt: "2026-05-16T00:00:06.000Z",
			result: { cancelled: true, requestId: "que_1" },
		}));
		expect(event).toMatchObject({ importance: "normal", severity: "warning", type: "question.rejected" });
	});

	test("question.debug breadcrumbs publish via the broker and stay silent without one", () => {
		publishQuestionDebug("no broker installed");
		const events = installBroker();
		publishQuestionDebug("answersAsUserMessage: steer delivery unavailable");
		expect(events).toEqual([{
			importance: "noisy",
			severity: "debug",
			source: "pi-questions",
			summary: "answersAsUserMessage: steer delivery unavailable",
			type: "question.debug",
		}]);
	});
});
