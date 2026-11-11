import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";

/** One process, named by its pid and its start time, so a later signal can
 * check that the pid still names the same process. */
export interface ProcessIdentity {
	pid: number;
	pgid: number;
	start: string;
}

interface ProcessRow extends ProcessIdentity {
	ppid: number;
}

/** Linux `/proc/<pid>/stat`: the fields after the parenthesized command are
 * state, ppid, pgrp, ... and starttime is the 20th of them. */
export function parseProcStat(pid: number, stat: string): ProcessRow | undefined {
	const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
	const ppid = Number(fields[1]);
	const pgid = Number(fields[2]);
	const start = fields[19];
	if (!Number.isInteger(ppid) || !Number.isInteger(pgid) || start === undefined) return undefined;
	return { pid, ppid, pgid, start };
}

/** `ps -A -o pid=,ppid=,pgid=,lstart=` rows; lstart holds spaces and comes last. */
export function parsePsRows(output: string): ProcessRow[] {
	return output.split("\n").flatMap((line) => {
		const match = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.+?)\s*$/.exec(line);
		return match ? [{ pid: Number(match[1]), ppid: Number(match[2]), pgid: Number(match[3]), start: match[4] }] : [];
	});
}

function processTable(): ProcessRow[] {
	if (process.platform === "linux") {
		return readdirSync("/proc").flatMap((name) => {
			if (!/^\d+$/.test(name)) return [];
			try {
				const row = parseProcStat(Number(name), readFileSync(`/proc/${name}/stat`, "utf8"));
				return row ? [row] : [];
			} catch {
				// The process exited between the directory read and this one.
				return [];
			}
		});
	}
	if (process.platform === "darwin") return parsePsRows(execFileSync("ps", ["-A", "-o", "pid=,ppid=,pgid=,lstart="], { encoding: "utf8" }));
	return [];
}

/** Every process below `root`, from one read of the process table. */
export function descendantsOf(root: number, table: readonly ProcessRow[] = processTable()): ProcessIdentity[] {
	const children = new Map<number, ProcessRow[]>();
	for (const row of table) children.set(row.ppid, [...(children.get(row.ppid) ?? []), row]);
	const found: ProcessIdentity[] = [];
	const queue = [root];
	while (queue.length > 0) {
		for (const child of children.get(queue.shift()!) ?? []) {
			found.push({ pid: child.pid, pgid: child.pgid, start: child.start });
			queue.push(child.pid);
		}
	}
	return found;
}

/** SIGKILL each process that still has the identity it was recorded with;
 * one that leads its own process group takes its group with it. */
export function killSurvivors(recorded: readonly ProcessIdentity[]): void {
	const now = new Map(processTable().map((row) => [row.pid, row]));
	for (const process_ of recorded) {
		const current = now.get(process_.pid);
		if (current === undefined || current.start !== process_.start) continue;
		try {
			process.kill(current.pgid === current.pid ? -current.pid : current.pid, "SIGKILL");
		} catch {
			// It exited after the table was read.
		}
	}
}
