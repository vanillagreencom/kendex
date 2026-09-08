import { appendFileSync } from "node:fs";
import { basename } from "node:path";

const command = basename(process.argv[1]!);
if (command !== "systemctl" && command !== "systemd-run") {
	process.stderr.write(`resource-probe-command=${JSON.stringify(command)}\n`);
	process.exit(1);
}
const log = process.env.RESOURCE_PROBE_LOG;
if (!log) {
	process.stderr.write("resource-probe-log=missing\n");
	process.exit(1);
}
const rawStatus = command === "systemctl" ? process.env.RESOURCE_SYSTEMCTL_STATUS : process.env.RESOURCE_SYSTEMD_RUN_STATUS;
const status = Number(rawStatus);
if (!Number.isInteger(status) || status < 0 || status > 255) {
	process.stderr.write(`resource-probe-status=${JSON.stringify(rawStatus) ?? "missing"}\n`);
	process.exit(1);
}
appendFileSync(log, JSON.stringify({ command, args: process.argv.slice(2) }) + "\n");
process.exit(status);
