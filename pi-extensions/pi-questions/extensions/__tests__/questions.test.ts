import { describe, expect, test } from "bun:test";

import { normalizeAnswers, normalizeRequest, questionRowCount } from "../question-model.js";

describe("question free-text fallback", () => {
	test("single-select questions without allowCustom get a Something else fallback", () => {
		const request = normalizeRequest({
			id: "que_single",
			questions: [{
				header: "Path",
				question: "Which path?",
				options: [{ label: "A" }, { label: "B" }],
			}],
		});

		const tab = request.questions[0];
		expect(tab.allowCustom).toBe(true);
		expect(tab.customLabel).toBe("Something else");
		expect(questionRowCount(tab)).toBe(3);
		expect(normalizeAnswers(request, [["Use C instead"]])).toEqual([["Use C instead"]]);
	});

	test("multi-select questions without allowCustom accept fixed plus fallback answers", () => {
		const request = normalizeRequest({
			id: "que_multi",
			questions: [{
				header: "Targets",
				multiple: true,
				question: "Which targets?",
				options: [{ label: "Docs" }, { label: "Tests" }],
			}],
		});

		const tab = request.questions[0];
		expect(tab.allowCustom).toBe(true);
		expect(tab.customLabel).toBe("Something else");
		expect(questionRowCount(tab)).toBe(3);
		expect(normalizeAnswers(request, [["Docs", "Release notes"]])).toEqual([["Docs", "Release notes"]]);
	});

	test("existing allowCustom true questions keep one custom row", () => {
		const request = normalizeRequest({
			id: "que_custom",
			questions: [{
				allowCustom: true,
				customLabel: "Type issue ID",
				header: "Issue",
				question: "Which issue?",
				options: [{ label: "Current" }, { label: "Skip" }],
			}],
		});

		const tab = request.questions[0];
		expect(tab.allowCustom).toBe(true);
		expect(tab.customLabel).toBe("Type issue ID");
		expect(questionRowCount(tab)).toBe(3);
		expect(normalizeAnswers(request, [["ABC-123"]])).toEqual([["ABC-123"]]);
	});

	test("allowCustom false does not disable fallback answer serialization", () => {
		const request = normalizeRequest({
			id: "que_false",
			questions: [{
				allowCustom: false,
				header: "Choice",
				question: "Pick one.",
				options: [{ label: "Only option" }],
			}],
		});
		const answers = normalizeAnswers(request, [["Something not listed"]]);

		expect(request.questions[0].allowCustom).toBe(true);
		expect(JSON.parse(JSON.stringify({ requestId: request.id, answers }))).toEqual({
			answers: [["Something not listed"]],
			requestId: "que_false",
		});
	});
});
