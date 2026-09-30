import { expect, test } from "bun:test";
import type { ProbeResult } from "../extensions/probes.js";
import { createSystemdUnitActiveProbe, createUserManagerReachability, planResourceControlledSpawn } from "../extensions/resource-control.js";
import { settings, spawnInput } from "./fixtures/resource-control.js";

const exited = (status: number): ProbeResult => ({ kind: "exited", status, stdout: "" });
const manager = "systemctl --user show-environment";
const isActive = (unit: string) => `systemctl --user is-active --quiet ${unit}`;

test("systemd unit liveness probe caches the user manager's reachability", async () => {
	const rows: {
		name: string;
		platform: NodeJS.Platform;
		units: string[];
		answers: Record<string, ProbeResult[]>;
		expected: { verdicts: (boolean | null)[]; calls: string[] };
	}[] = [
		{
			name: "a reachable manager is probed once for many units",
			platform: "linux", units: ["a.service", "b.service", "c.service"],
			answers: { [manager]: [exited(0)], [isActive("a.service")]: [exited(0)], [isActive("b.service")]: [exited(3)], [isActive("c.service")]: [exited(4)] },
			expected: { verdicts: [true, false, null], calls: [manager, isActive("a.service"), isActive("b.service"), isActive("c.service")] },
		},
		{
			name: "an unreachable manager is cached and no unit is queried",
			platform: "linux", units: ["a.service", "b.service"],
			answers: { [manager]: [exited(1)] },
			expected: { verdicts: [null, null], calls: [manager] },
		},
		{
			name: "a missing systemctl is cached as unreachable",
			platform: "linux", units: ["a.service", "b.service"],
			answers: { [manager]: [{ kind: "missing" }] },
			expected: { verdicts: [null, null], calls: [manager] },
		},
		{
			name: "a spawn failure other than a missing systemctl is retried by the next unit",
			platform: "linux", units: ["a.service", "b.service"],
			answers: { [manager]: [{ kind: "unsettled", cause: "spawn-failed", code: "EAGAIN" }, exited(0)], [isActive("b.service")]: [exited(0)] },
			expected: { verdicts: [null, true], calls: [manager, manager, isActive("b.service")] },
		},
		{
			name: "a timed-out manager probe is retried by the next unit",
			platform: "linux", units: ["a.service", "b.service"],
			answers: { [manager]: [{ kind: "unsettled", cause: "timed-out" }, exited(0)], [isActive("b.service")]: [exited(0)] },
			expected: { verdicts: [null, true], calls: [manager, manager, isActive("b.service")] },
		},
		{
			name: "a signalled manager probe is retried by the next unit",
			platform: "linux", units: ["a.service", "b.service"],
			answers: { [manager]: [{ kind: "unsettled", cause: "signalled", signal: "SIGTERM" }, exited(1)] },
			expected: { verdicts: [null, null], calls: [manager, manager] },
		},
		{
			name: "a timed-out unit query is unknown",
			platform: "linux", units: ["a.service"],
			answers: { [manager]: [exited(0)], [isActive("a.service")]: [{ kind: "unsettled", cause: "timed-out" }] },
			expected: { verdicts: [null], calls: [manager, isActive("a.service")] },
		},
		{
			name: "no probe runs off Linux",
			platform: "darwin", units: ["a.service"],
			answers: {},
			expected: { verdicts: [null], calls: [] },
		},
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "systemd unit probe table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const calls: string[] = [];
		const run = async (file: string, args: string[]) => {
			const call = [file, ...args].join(" ");
			calls.push(call);
			const answer = row.answers[call]?.shift();
			if (!answer) throw new Error(`systemd_probe_test.unexpected_call=${call}`);
			return answer;
		};
		const probe = createSystemdUnitActiveProbe({ platform: () => row.platform, run, userManager: createUserManagerReachability({ run }) });
		const verdicts = [];
		for (const unit of row.units) verdicts.push(await probe(unit));
		expect({ verdicts, calls }, row.name).toStrictEqual(row.expected);
	}
});

test("concurrent unit probes share one manager probe", async () => {
	const calls: string[] = [];
	let answerManager: ((result: ProbeResult) => void) | null = null;
	const run = (file: string, args: string[]): Promise<ProbeResult> => {
		const call = [file, ...args].join(" ");
		calls.push(call);
		if (call === manager) return new Promise((resolve) => { answerManager = resolve; });
		return Promise.resolve(exited(0));
	};
	const probe = createSystemdUnitActiveProbe({ platform: () => "linux", run, userManager: createUserManagerReachability({ run }) });
	const verdicts = Promise.all(["a.service", "b.service"].map((unit) => probe(unit)));
	await Promise.resolve();
	answerManager!(exited(0));
	expect({ verdicts: await verdicts, calls }).toStrictEqual({ verdicts: [true, true], calls: [manager, isActive("a.service"), isActive("b.service")] });
});

test("spawn planning and unit probes read one user manager answer", async () => {
	const rows: { name: string; first: "sync" | "async"; answers: ProbeResult[]; expected: { answers: (boolean | null)[]; calls: string[] } }[] = [
		{ name: "a synchronous answer serves the unit probe", first: "sync", answers: [exited(0)], expected: { answers: [true, true], calls: [`sync ${manager}`] } },
		{ name: "an asynchronous answer serves spawn planning", first: "async", answers: [exited(1)], expected: { answers: [false, false], calls: [`async ${manager}`] } },
		{ name: "a synchronous timeout settles nothing", first: "sync", answers: [{ kind: "unsettled", cause: "timed-out" }, exited(0)], expected: { answers: [null, true], calls: [`sync ${manager}`, `async ${manager}`] } },
		{ name: "a missing systemctl settles unreachable", first: "sync", answers: [{ kind: "missing" }], expected: { answers: [false, false], calls: [`sync ${manager}`] } },
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "user manager memo table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const calls: string[] = [];
		const answer = (mode: string, file: string, args: string[]): ProbeResult => {
			calls.push(`${mode} ${[file, ...args].join(" ")}`);
			const result = row.answers.shift();
			if (!result) throw new Error(`systemd_probe_test.unexpected_call=${file} ${args.join(" ")}`);
			return result;
		};
		const reach = createUserManagerReachability({
			run: async (file, args) => answer("async", file, args),
			runSync: (file, args) => answer("sync", file, args),
		});
		const answers = row.first === "sync" ? [reach.sync(), await reach.check()] : [await reach.check(), reach.sync()];
		expect({ answers, calls }, row.name).toStrictEqual(row.expected);
	}
});

test("spawn planning asks an unanswering user manager once per settings", () => {
	let syncCalls = 0;
	const userManager = createUserManagerReachability({
		async run() { throw new Error("systemd_probe_test.unexpected_async_probe"); },
		runSync() { syncCalls++; return { kind: "unsettled", cause: "timed-out" }; },
	});
	// A settings shape no other suite plans with, so the per-settings cache starts empty.
	const input = spawnInput({ settings: settings({ mode: "systemd-run", cpuWeight: 4321 }), probes: { platform: "linux", commandExists: () => true, userManager } });
	const plans = [planResourceControlledSpawn(input), planResourceControlledSpawn(input)].map((plan) => plan.file);
	expect({ plans, syncCalls }).toStrictEqual({ plans: ["/bin/bash", "/bin/bash"], syncCalls: 1 });
});
