import { expect, test } from "bun:test";
import type { ProbeResult } from "../extensions/probes.js";
import { createSystemdUnitActiveProbe } from "../extensions/resource-control.js";

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
			answers: { [manager]: [{ kind: "spawn-failed", code: "ENOENT" }] },
			expected: { verdicts: [null, null], calls: [manager] },
		},
		{
			name: "a timed-out manager probe is retried by the next unit",
			platform: "linux", units: ["a.service", "b.service"],
			answers: { [manager]: [{ kind: "timed-out" }, exited(0)], [isActive("b.service")]: [exited(0)] },
			expected: { verdicts: [null, true], calls: [manager, manager, isActive("b.service")] },
		},
		{
			name: "a signalled manager probe is retried by the next unit",
			platform: "linux", units: ["a.service", "b.service"],
			answers: { [manager]: [{ kind: "signalled", signal: "SIGTERM" }, exited(1)] },
			expected: { verdicts: [null, null], calls: [manager, manager] },
		},
		{
			name: "a timed-out unit query is unknown",
			platform: "linux", units: ["a.service"],
			answers: { [manager]: [exited(0)], [isActive("a.service")]: [{ kind: "timed-out" }] },
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
		const probe = createSystemdUnitActiveProbe({
			platform: () => row.platform,
			async run(file, args) {
				const call = [file, ...args].join(" ");
				calls.push(call);
				const answer = row.answers[call]?.shift();
				if (!answer) throw new Error(`systemd_probe_test.unexpected_call=${call}`);
				return answer;
			},
		});
		const verdicts = [];
		for (const unit of row.units) verdicts.push(await probe(unit));
		expect({ verdicts, calls }, row.name).toStrictEqual(row.expected);
	}
});

test("concurrent unit probes share one manager probe", async () => {
	const calls: string[] = [];
	let answerManager: ((result: ProbeResult) => void) | null = null;
	const probe = createSystemdUnitActiveProbe({
		platform: () => "linux",
		run(file, args) {
			const call = [file, ...args].join(" ");
			calls.push(call);
			if (call === manager) return new Promise((resolve) => { answerManager = resolve; });
			return Promise.resolve(exited(0));
		},
	});
	const verdicts = Promise.all(["a.service", "b.service"].map((unit) => probe(unit)));
	await Promise.resolve();
	answerManager!(exited(0));
	expect({ verdicts: await verdicts, calls }).toStrictEqual({ verdicts: [true, true], calls: [manager, isActive("a.service"), isActive("b.service")] });
});
