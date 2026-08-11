import { describe, expect, test } from "bun:test";

import { normalizeRequest } from "../question-model.js";
import {
	formatOptionRows,
	isRpcMode,
	parseMultiSelection,
	presentQuestion,
	rpcDialogUI,
	runRpcQuestionnaire,
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
}

function fakeDialogs(responses: Array<string | undefined>): FakeDialogs {
	const queue = [...responses];
	const calls: DialogCall[] = [];
	return {
		calls,
		input(title, placeholder) {
			calls.push({ method: "input", placeholder, title });
			if (queue.length === 0) throw new Error("fake dialog queue exhausted");
			return Promise.resolve(queue.shift());
		},
		select(title, options) {
			calls.push({ method: "select", options, title });
			if (queue.length === 0) throw new Error("fake dialog queue exhausted");
			return Promise.resolve(queue.shift());
		},
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
		expect(isRpcMode({ mode: "rpc" })).toBe(true);
		expect(isRpcMode({ mode: "interactive" })).toBe(false);
		expect(isRpcMode({})).toBe(false);
		expect(isRpcMode(undefined)).toBe(false);
	});

	test("rpcDialogUI requires callable select and input", () => {
		expect(rpcDialogUI(undefined)).toBeUndefined();
		expect(rpcDialogUI({ select: () => Promise.resolve(undefined) })).toBeUndefined();
		expect(rpcDialogUI({ input: () => Promise.resolve(undefined) })).toBeUndefined();
		const ui = { input: () => Promise.resolve(undefined), select: () => Promise.resolve(undefined) };
		expect(rpcDialogUI(ui)).toBe(ui as RpcDialogUI);
	});
});

describe("rpc questionnaire walker", () => {
	test("single select answers with the chosen option label", async () => {
		const request = singleRequest();
		const dialogs = fakeDialogs(["1. A — keep going"]);
		const outcome = await runRpcQuestionnaire(dialogs, request);

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
		const outcome = await runRpcQuestionnaire(dialogs, request);

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
		const outcome = await runRpcQuestionnaire(dialogs, request);

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
		const outcome = await runRpcQuestionnaire(dialogs, request);

		expect(outcome).toEqual({ answers: [["B"], ["Docs", "Release notes"], ["Fast"]], kind: "answered" });
	});

	test("dismissing a dialog cancels the questionnaire without further dialogs", async () => {
		const request = multiTabRequest();
		const dialogs = fakeDialogs(["1. A", undefined]);
		const outcome = await runRpcQuestionnaire(dialogs, request);

		expect(outcome).toEqual({ kind: "cancelled" });
		expect(dialogs.calls).toHaveLength(2);
	});

	test("dismissing the custom-text follow-up cancels too", async () => {
		const request = singleRequest();
		const dialogs = fakeDialogs(["3. Something else (type your own answer)", undefined]);
		const outcome = await runRpcQuestionnaire(dialogs, request);

		expect(outcome).toEqual({ kind: "cancelled" });
	});

	test("repeated invocations are independent", async () => {
		const request = singleRequest();
		const first = await runRpcQuestionnaire(fakeDialogs([undefined]), request);
		const second = await runRpcQuestionnaire(fakeDialogs(["2. B"]), request);
		const third = await runRpcQuestionnaire(fakeDialogs(["1. A — keep going"]), request);

		expect(first).toEqual({ kind: "cancelled" });
		expect(second).toEqual({ answers: [["B"]], kind: "answered" });
		expect(third).toEqual({ answers: [["A"]], kind: "answered" });
	});
});

describe("multi-select parsing", () => {
	const tab = () => multiTabRequest().questions[1];

	test("comma or space separated numbers map to option labels, deduped", () => {
		expect(parseMultiSelection("1,2,1", tab())).toEqual({ labels: ["Docs", "Tests"], wantsCustom: false });
		expect(parseMultiSelection(" 2 1 ", tab())).toEqual({ labels: ["Tests", "Docs"], wantsCustom: false });
	});

	test("custom row number requests the follow-up input; out-of-range numbers are ignored", () => {
		expect(parseMultiSelection("1,3", tab())).toEqual({ labels: ["Docs"], wantsCustom: true });
		expect(parseMultiSelection("9", tab())).toEqual({ labels: [], wantsCustom: false });
	});

	test("non-numeric input becomes a whole free-text custom answer", () => {
		expect(parseMultiSelection("Docs and a migration guide", tab())).toEqual({
			labels: ["Docs and a migration guide"],
			wantsCustom: false,
		});
		expect(parseMultiSelection("   ", tab())).toEqual({ labels: [], wantsCustom: false });
	});
});

describe("presentQuestion routing", () => {
	test("explicit rpc mode uses the dialog walker even without custom UI", async () => {
		const request = singleRequest();
		const dialogs = fakeDialogs(["2. B"]);
		const outcome = await presentQuestion(request, {
			dialogs,
			hasUI: false,
			isSettled: () => false,
			rpcMode: true,
		});

		expect(outcome).toEqual({ answers: [["B"]], kind: "answered" });
	});

	test("rpc mode without dialogs is a clear error, not a hang", async () => {
		const outcome = await presentQuestion(singleRequest(), {
			dialogs: undefined,
			hasUI: false,
			isSettled: () => false,
			rpcMode: true,
		});

		expect(outcome?.kind).toBe("unavailable");
		expect((outcome as Extract<PresentOutcome, { kind: "unavailable" }>).error).toContain("select/input");
	});

	test("custom() resolving undefined falls back to the dialog walker", async () => {
		const request = singleRequest();
		const dialogs = fakeDialogs(["1. A — keep going"]);
		let customOpened = 0;
		const outcome = await presentQuestion(request, {
			dialogs,
			hasUI: true,
			isSettled: () => false,
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
			isSettled: () => false,
			openCustom: () => Promise.resolve(undefined),
			rpcMode: false,
		});

		expect(outcome?.kind).toBe("unavailable");
	});

	test("custom() completing the request stays on the custom path", async () => {
		const dialogs = fakeDialogs([]);
		const outcome = await presentQuestion(singleRequest(), {
			dialogs,
			hasUI: true,
			isSettled: () => true,
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
			isSettled: () => false,
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
