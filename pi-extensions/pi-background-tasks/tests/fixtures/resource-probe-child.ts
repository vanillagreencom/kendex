import { defaultSystemdUnitActive, planResourceControlledSpawn } from "../../extensions/resource-control.js";
import { settings, spawnInput } from "./resource-control.js";

Date.now = () => 123456;
const plan = planResourceControlledSpawn(spawnInput({
	settings: settings({ mode: "systemd-run", cpuWeight: 25, ioWeight: 50, nice: 12, ioniceLevel: 6 }),
	// The default availability function still executes both fake commands through PATH.
	probes: { platform: "linux", commandExists: (command) => command === "systemctl" || command === "systemd-run" },
}));
// The unit probe reads the user manager answer spawn planning settled.
const unitActive = await defaultSystemdUnitActive("kendex-pi-bg-bg-7-123456.service");
process.stdout.write(JSON.stringify({ pid: process.pid, plan, unitActive }));
