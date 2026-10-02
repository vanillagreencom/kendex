import { describe, expect, test } from "bun:test";

import { unsettledDialogOptions } from "./helpers/runtime.js";
import { normalizeRequest } from "../question-model.js";
import {
	formatOptionRows,
	isRpcMode,
	parseMultiSelection,
	presentQuestion,
	rpcDialogUI,
	runRpcQuestionnaire,
	type DialogOptions,
	type PresentOutcome,
	type RpcDialogUI,
} from "../rpc-fallback.js";

interface DialogCall {
	method: "select" | "input";
	title: string;
	options?: string[];
	placeholder?: string;
}

interface FakeDialogs extends RpcDialogUI {
	calls: DialogCall[];
	/** The options argument of each dialog call, in call order. */
	received?: unknown[];
}

function fakeDialogs(responses: Array<string | undefined>): FakeDialogs {
	const queue = [...responses];
	const calls: DialogCall[] = [];
	const received: unknown[] = [];
	return {
		calls,
		input(title, placeholder, opts) {
			calls.push({ method: "input", placeholder, title });
			received.push(opts);
			if (queue.length === 0) throw new Error("fake dialog queue exhausted");
			return Promise.resolve(queue.shift());
		},
		select(title, options, opts) {
			calls.push({ method: "select", options, title });
			received.push(opts);
			if (queue.length === 0) throw new Error("fake dialog queue exhausted");
			return Promise.resolve(queue.shift());
		},
		received,
	};
}

function singleRequest() {
	return normalizeRequest({
		id: "que_rpc_single",
		questions: [{
			header: "Path",
			options: [{ description: "keep going", label: "A" }, { label: "B" }],
			question: "Which path?",
		}],
	});
}

function multiTabRequest() {
	return normalizeRequest({
		id: "que_rpc_multi",
		questions: [
			{ header: "Path", options: [{ label: "A" }, { label: "B" }], question: "Which path?" },
			{ header: "Targets", multiple: true, options: [{ label: "Docs" }, { label: "Tests" }], question: "Which targets?" },
			{ header: "Speed", options: [{ label: "Fast" }, { label: "Slow" }], question: "How fast?" },
		],
	});
}

describe("rpc mode detection", () => {
	test("isRpcMode detects explicit rpc mode only", () => {
		for (const [context, expected] of [
			[{ mode: "rpc" }, true], [{ mode: "interactive" }, false], [{}, false], [undefined, false],
		] as const) {
			expect(isRpcMode(context)).toBe(expected);
		}
	});

	test("rpcDialogUI requires callable select and input", () => {
		const ui = { input: () => Promise.resolve(undefined), select: () => Promise.resolve(undefined) };
		for (const [candidate, expected] of [
			[undefined, undefined], [{ select: ui.select }, undefined], [{ input: ui.input }, undefined], [ui, ui],
		] as const) {
			expect(rpcDialogUI(candidate)).toBe(expected);
		}
	});
});

describe("rpc questionnaire walker", () => {
	test("single select answers with the chosen option label", async () => {
		const request = singleRequest();
		const dialogs = fakeDialogs(["1. A — keep going"]);
		const outcome = await runRpcQuestionnaire(dialogs, request, unsettledDialogOptions());

		expect(outcome).toEqual({ answers: [["A"]], kind: "answered" });
		expect(dialogs.calls).toEqual([{
			method: "select",
			options: ["1. A — keep going", "2. B", "3. Something else (type your own answer)"],
			title: "Path: Which path?",
		}]);
	});

	test("choosing the custom row prompts for free text", async () => {
		const request = singleRequest();
		const dialogs = fakeDialogs(["3. Something else (type your own answer)", "  Use C instead  "]);
		const outcome = await runRpcQuestionnaire(dialogs, request, unsettledDialogOptions());

		expect(outcome).toEqual({ answers: [["Use C instead"]], kind: "answered" });
		expect(dialogs.calls[1]).toEqual({
			method: "input",
			placeholder: "Type your answer, then press enter.",
			title: "Path: Something else",
		});
	});

	test("walks multiple questions in order and preserves the answers shape", async () => {
		const request = multiTabRequest();
		const dialogs = fakeDialogs(["1. A", "1,2", "2. Slow"]);
		const outcome = await runRpcQuestionnaire(dialogs, request, unsettledDialogOptions());

		expect(outcome).toEqual({ answers: [["A"], ["Docs", "Tests"], ["Slow"]], kind: "answered" });
		expect(dialogs.calls.map((call) => call.method)).toEqual(["select", "input", "select"]);
		expect(dialogs.calls[0].title).toBe("Path (1/3): Which path?");
		expect(dialogs.calls[1].title).toContain("Targets (2/3): Which targets?");
		expect(dialogs.calls[1].title).toContain("1. Docs");
		expect(dialogs.calls[2].title).toBe("Speed (3/3): How fast?");
	});

	test("multi-select custom number triggers a follow-up text input", async () => {
		const request = multiTabRequest();
		const dialogs = fakeDialogs(["2. B", "1,3", "Release notes", "1. Fast"]);
		const outcome = await runRpcQuestionnaire(dialogs, request, unsettledDialogOptions());

		expect(outcome).toEqual({ answers: [["B"], ["Docs", "Release notes"], ["Fast"]], kind: "answered" });
	});

	test("dismissing a dialog cancels the questionnaire without further dialogs", async () => {
		const request = multiTabRequest();
		const dialogs = fakeDialogs(["1. A", undefined]);
		const outcome = await runRpcQuestionnaire(dialogs, request, unsettledDialogOptions());

		expect(outcome).toEqual({ kind: "cancelled" });
		expect(dialogs.calls).toHaveLength(2);
	});

	test("dismissing the custom-text follow-up cancels too", async () => {
		const request = singleRequest();
		const dialogs = fakeDialogs(["3. Something else (type your own answer)", undefined]);
		const outcome = await runRpcQuestionnaire(dialogs, request, unsettledDialogOptions());

		expect(outcome).toEqual({ kind: "cancelled" });
	});

	test("abandons silently when the request settles externally mid-walk", async () => {
		const request = multiTabRequest();
		const settle = new AbortController();
		const base = fakeDialogs(["1. A"]);
		const dialogs: FakeDialogs = {
			calls: base.calls,
			input: base.input,
			select: async (title, options, opts) => {
				const choice = await base.select(title, options, opts);
				settle.abort();
				return choice;
			},
		};
		const outcome = await runRpcQuestionnaire(dialogs, request, { signal: settle.signal });

		expect(outcome).toEqual({ kind: "external" });
		expect(dialogs.calls).toHaveLength(1);
	});

	test("every dialog receives the request's dialog options", async () => {
		const options: DialogOptions = { signal: new AbortController().signal, timeout: 1_800_000 };
		const dialogs = fakeDialogs(["1. A", "1,3", "Release notes", "2. Slow"]);
		const outcome = await runRpcQuestionnaire(dialogs, multiTabRequest(), options);

		expect(outcome).toEqual({ answers: [["A"], ["Docs", "Release notes"], ["Slow"]], kind: "answered" });
		expect(dialogs.calls.map(({ method }, index) => ({ method, received: dialogs.received?.[index] === options }))).toEqual([
			{ method: "select", received: true },
			{ method: "input", received: true },
			{ method: "input", received: true },
			{ method: "select", received: true },
		]);
	});

	test("never opens a dialog when the request is already settled", async () => {
		const dialogs = fakeDialogs([]);
		const outcome = await runRpcQuestionnaire(dialogs, singleRequest(), { signal: AbortSignal.abort() });

		expect(outcome).toEqual({ kind: "external" });
		expect(dialogs.calls).toHaveLength(0);
	});

	test("blank custom text re-shows the question instead of answering blank", async () => {
		const request = singleRequest();
		const customRow = "3. Something else (type your own answer)";
		const dialogs = fakeDialogs([customRow, "   ", customRow, "Real answer"]);
		const outcome = await runRpcQuestionnaire(dialogs, request, unsettledDialogOptions());

		expect(outcome).toEqual({ answers: [["Real answer"]], kind: "answered" });
		expect(dialogs.calls[2].title.split("\n")[0]).toBe("custom-answer=empty");
		expect(dialogs.calls[2].title.split("\n").at(-1)).toBe("Path: Which path?");
	});

	test("blank unlisted select text re-shows the question instead of answering blank", async () => {
		const dialogs = fakeDialogs(["", "2. B"]);
		const outcome = await runRpcQuestionnaire(dialogs, singleRequest(), unsettledDialogOptions());

		expect(outcome).toEqual({ answers: [["B"]], kind: "answered" });
		expect(dialogs.calls[1].title.split("\n")[0]).toBe("answer=empty");
	});

	test("persistent blank input cancels after bounded re-prompts, never a false answer", async () => {
		const customRow = "3. Something else (type your own answer)";
		const dialogs = fakeDialogs([customRow, "", customRow, "", customRow, "", customRow, "", customRow, ""]);
		const outcome = await runRpcQuestionnaire(dialogs, singleRequest(), unsettledDialogOptions());

		expect(outcome).toEqual({ kind: "cancelled" });
		expect(dialogs.calls).toHaveLength(10);
	});

	test("out-of-range multi-select numbers re-prompt with an error note", async () => {
		const request = multiTabRequest();
		const dialogs = fakeDialogs(["1. A", "9", "1,2", "2. Slow"]);
		const outcome = await runRpcQuestionnaire(dialogs, request, unsettledDialogOptions());

		expect(outcome).toEqual({ answers: [["A"], ["Docs", "Tests"], ["Slow"]], kind: "answered" });
		expect(dialogs.calls[2].title.split("\n")[0]).toBe("option-range=9:1:3");
		expect(dialogs.calls[2].title.split("\n")[1]).toBe("Option numbers must be between 1 and 3.");
		expect(dialogs.calls[2].title.split("\n")[2]).toBe("Targets (2/3): Which targets?");
	});

	test("multi-select option list is never truncated away, custom row included", async () => {
		const request = normalizeRequest({
			id: "que_rpc_long",
			questions: [{
				header: "Pick",
				multiple: true,
				options: Array.from({ length: 12 }, (_, i) => ({ description: "x".repeat(300), label: `Option ${i + 1}` })),
				question: `Long question ${"y".repeat(700)}`,
			}],
		});
		const dialogs = fakeDialogs(["1,12"]);
		const outcome = await runRpcQuestionnaire(dialogs, request, unsettledDialogOptions());

		expect(outcome).toEqual({ answers: [["Option 1", "Option 12"]], kind: "answered" });
		const lines = dialogs.calls[0].title.split("\n");
		expect(lines).toHaveLength(14);
		expect(lines[13]).toBe("13. Something else (type your own answer)");
	});

	test("control-state words typed as custom answers arrive as answers, not control states", async () => {
		const customRow = "3. Something else (type your own answer)";
		for (const word of ["cancelled", "abandoned", "blank", "external", "answers", "text"]) {
			const single = await runRpcQuestionnaire(fakeDialogs([customRow, word]), singleRequest(), unsettledDialogOptions());
			expect(single).toEqual({ answers: [[word]], kind: "answered" });
		}
		const multi = await runRpcQuestionnaire(
			fakeDialogs(["1. A", "1,3", "cancelled", "2. Slow"]),
			multiTabRequest(),
			unsettledDialogOptions(),
		);
		expect(multi).toEqual({ answers: [["A"], ["Docs", "cancelled"], ["Slow"]], kind: "answered" });
	});

	test("multi-question requests offer a skip row; skipping yields an empty answer like the TUI confirm tab", async () => {
		const request = multiTabRequest();
		const dialogs = fakeDialogs(["4. Skip (no selection)", "", "1. Fast"]);
		const outcome = await runRpcQuestionnaire(dialogs, request, unsettledDialogOptions());

		expect(outcome).toEqual({ answers: [[], [], ["Fast"]], kind: "answered" });
		expect(dialogs.calls[0].options).toEqual([
			"1. A",
			"2. B",
			"3. Something else (type your own answer)",
			"4. Skip (no selection)",
		]);
	});

	test("single-question single-select offers no skip row, matching the TUI which cannot submit empty there", async () => {
		const dialogs = fakeDialogs(["2. B"]);
		await runRpcQuestionnaire(dialogs, singleRequest(), unsettledDialogOptions());

		expect(dialogs.calls[0].options).toEqual(["1. A — keep going", "2. B", "3. Something else (type your own answer)"]);
	});

	test("repeated invocations are independent", async () => {
		const request = singleRequest();
		const first = await runRpcQuestionnaire(fakeDialogs([undefined]), request, unsettledDialogOptions());
		const second = await runRpcQuestionnaire(fakeDialogs(["2. B"]), request, unsettledDialogOptions());
		const third = await runRpcQuestionnaire(fakeDialogs(["1. A — keep going"]), request, unsettledDialogOptions());

		expect(first).toEqual({ kind: "cancelled" });
		expect(second).toEqual({ answers: [["B"]], kind: "answered" });
		expect(third).toEqual({ answers: [["A"]], kind: "answered" });
	});
});

describe("multi-select parsing", () => {
	const tab = () => multiTabRequest().questions[1];

	test("maps numeric and free-text selections without silent range failures", () => {
		for (const [raw, expected] of [
			["1,2,1", { labels: ["Docs", "Tests"], wantsCustom: false }],
			[" 2 1 ", { labels: ["Tests", "Docs"], wantsCustom: false }],
			["1,3", { labels: ["Docs"], wantsCustom: true }],
			["9", { error: "option-range=9:1:3\nOption numbers must be between 1 and 3." }],
			["0", { error: "option-range=0:1:3\nOption numbers must be between 1 and 3." }],
			["12", { error: "option-range=12:1:3\nOption numbers must be between 1 and 3." }],
			["Docs and a migration guide", { labels: ["Docs and a migration guide"], wantsCustom: false }],
			["   ", { labels: [], wantsCustom: false }],
		] as const) {
			expect(parseMultiSelection(raw, tab())).toEqual(expected);
		}
	});
});

describe("presentQuestion routing", () => {
	test("explicit rpc mode uses the dialog walker even without custom UI", async () => {
		const request = singleRequest();
		const dialogs = fakeDialogs(["2. B"]);
		const outcome = await presentQuestion(request, {
			dialogs,
			hasUI: false,
			dialogOptions: unsettledDialogOptions(),
			rpcMode: true,
		});

		expect(outcome).toEqual({ answers: [["B"]], kind: "answered" });
	});

	test("rpc mode without dialogs is a clear error, not a hang", async () => {
		const outcome = await presentQuestion(singleRequest(), {
			dialogs: undefined,
			hasUI: false,
			dialogOptions: unsettledDialogOptions(),
			rpcMode: true,
		});

		expect(outcome?.kind).toBe("unavailable");
		expect((outcome as Extract<PresentOutcome, { kind: "unavailable" }>).error.split("\n")[0]).toBe("question-ui=rpc:unavailable");
	});

	test("custom() resolving undefined falls back to the dialog walker", async () => {
		const request = singleRequest();
		const dialogs = fakeDialogs(["1. A — keep going"]);
		let customOpened = 0;
		const outcome = await presentQuestion(request, {
			dialogs,
			hasUI: true,
			dialogOptions: unsettledDialogOptions(),
			openCustom: () => {
				customOpened += 1;
				return Promise.resolve(undefined);
			},
			rpcMode: false,
		});

		expect(customOpened).toBe(1);
		expect(outcome).toEqual({ answers: [["A"]], kind: "answered" });
	});

	test("custom() resolving undefined without dialogs is a clear error", async () => {
		const outcome = await presentQuestion(singleRequest(), {
			dialogs: undefined,
			hasUI: true,
			dialogOptions: unsettledDialogOptions(),
			openCustom: () => Promise.resolve(undefined),
			rpcMode: false,
		});

		expect(outcome?.kind).toBe("unavailable");
		expect((outcome as Extract<PresentOutcome, { kind: "unavailable" }>).error.split("\n")[0]).toBe("question-ui=custom:unavailable");
	});

	test("custom() completing the request stays on the custom path", async () => {
		const dialogs = fakeDialogs([]);
		const outcome = await presentQuestion(singleRequest(), {
			dialogs,
			hasUI: true,
			dialogOptions: { signal: AbortSignal.abort() },
			openCustom: () => Promise.resolve({ answers: [["A"]], requestId: "que_rpc_single" }),
			rpcMode: false,
		});

		expect(outcome).toEqual({ kind: "external" });
		expect(dialogs.calls).toHaveLength(0);
	});

	test("headless non-rpc contexts leave the request pending for bridge replies", async () => {
		const outcome = await presentQuestion(singleRequest(), {
			dialogs: fakeDialogs([]),
			hasUI: false,
			dialogOptions: unsettledDialogOptions(),
			rpcMode: false,
		});

		expect(outcome).toBeUndefined();
	});
});

describe("option row formatting", () => {
	test("rows are numbered with descriptions folded in and the custom row last", () => {
		const rows = formatOptionRows(singleRequest().questions[0]);
		expect(rows).toEqual(["1. A — keep going", "2. B", "3. Something else (type your own answer)"]);
	});
});
