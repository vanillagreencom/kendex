import { planResourceControlledSpawn } from "../../extensions/resource-control.js";
import { settings, spawnInput } from "./resource-control.js";

Date.now = () => 123456;
const plan = planResourceControlledSpawn(spawnInput({
	settings: settings({ mode: "systemd-run", cpuWeight: 25, ioWeight: 50, nice: 12, ioniceLevel: 6 }),
	// The default availability function still executes both fake commands through PATH.
	probes: { platform: "linux", commandExists: (command) => command === "systemctl" || command === "systemd-run" },
}));
process.stdout.write(JSON.stringify({ pid: process.pid, plan }));
