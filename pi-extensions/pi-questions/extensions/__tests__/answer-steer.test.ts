import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import { emitAnswerSteer, formatAnswerSteerMessage } from "../answer-steer.js";
import { normalizeRequest } from "../question-model.js";

describe("answer steer formatting", () => {
	test("single question matches the quoted issue format", () => {
		const request = normalizeRequest({
			questions: [{ header: "Path", question: "Which path?", options: [{ label: "A" }, { label: "B" }] }],
		});
		expect(formatAnswerSteerMessage(request, [["A"]])).toBe("> Which path?\n\nA");
	});

	test("multi-question requests emit one header-prefixed block per tab", () => {
		const request = normalizeRequest({
			questions: [
				{ header: "Path", question: "Which path?", options: [{ label: "A" }] },
				{ header: "Targets", multiple: true, question: "Which targets?", options: [{ label: "Docs" }, { label: "Tests" }] },
			],
		});
		expect(formatAnswerSteerMessage(request, [["A"], ["Docs", "Tests"]])).toBe(
			"> Path: Which path?\n\nA\n\n> Targets: Which targets?\n\nDocs, Tests",
		);
	});

	test("empty tab answers render as no selection", () => {
		const request = normalizeRequest({
			questions: [
				{ header: "Path", question: "Which path?", options: [{ label: "A" }] },
				{ header: "Targets", multiple: true, question: "Which targets?", options: [{ label: "Docs" }] },
			],
		});
		expect(formatAnswerSteerMessage(request, [["A"], []])).toBe(
			"> Path: Which path?\n\nA\n\n> Targets: Which targets?\n\n(no selection)",
		);
	});

	test("multi-line questions quote every line", () => {
		expect(formatAnswerSteerMessage({ questions: [{ header: "Q", question: "Line one\nLine two" }] }, [["Yes"]])).toBe(
			"> Line one\n> Line two\n\nYes",
		);
	});

	test("missing request falls back to question numbering", () => {
		expect(formatAnswerSteerMessage(undefined, [["Yes"]])).toBe("> Question 1\n\nYes");
	});
});

describe("answer steer emission", () => {
	const request = { questions: [{ header: "Path", question: "Which path?" }] };

	test("delivers one steer user message when the host supports it", () => {
		const calls: Array<{ content: string; options?: { deliverAs?: string } }> = [];
		const host = {
			sendUserMessage(content: string, options?: { deliverAs?: "steer" | "followUp" }) {
				calls.push({ content, options });
			},
		};
		let noted = 0;
		expect(emitAnswerSteer(host, request, [["A"]], () => { noted += 1; })).toBe(true);
		expect(calls).toEqual([{ content: "> Which path?\n\nA", options: { deliverAs: "steer" } }]);
		expect(noted).toBe(0);
	});

	test("hosts without sendUserMessage degrade silently", () => {
		let noted = 0;
		expect(emitAnswerSteer({}, request, [["A"]], () => { noted += 1; })).toBe(false);
		expect(noted).toBe(1);
	});

	test("synchronous send failures degrade silently", () => {
		let noted = 0;
		const host = { sendUserMessage: () => { throw new Error("deliverAs unsupported"); } };
		expect(emitAnswerSteer(host, request, [["A"]], () => { noted += 1; })).toBe(false);
		expect(noted).toBe(1);
	});

	test("rejected send promises are absorbed", async () => {
		let noted = 0;
		const host = { sendUserMessage: () => Promise.reject(new Error("agent still streaming")) };
		expect(emitAnswerSteer(host, request, [["A"]], () => { noted += 1; })).toBe(true);
		await Promise.resolve();
		await Promise.resolve();
		expect(noted).toBe(1);
	});
});

describe("questions.ts steer wiring", () => {
	const source = readFileSync(new URL("../questions.ts", import.meta.url), "utf8");

	test("emission is gated on the answersAsUserMessage setting, default off", () => {
		expect(source).toContain('settingBoolean("answersAsUserMessage", false');
	});

	test("answered events reach emitAnswerSteer with the original request", () => {
		expect(source).toContain("emitAnswerSteer(pi, event.request, event.result.answers");
	});

	test("answered and rejected events publish the originating request", () => {
		expect(source.replace(/\s+/g, " ")).toContain("openedAt, request, requestId: request.id, result: finalResult");
	});
});
