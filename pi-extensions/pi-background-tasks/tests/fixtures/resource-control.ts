import type { ResourceControlProbes, ResourceControlSettings, ResourceControlSpawnInput } from "../../extensions/resource-control.js";

export const command = "printf 'a b'; cat <<'EOF'\n$HOME && *\nEOF";

export function settings(overrides: Partial<ResourceControlSettings> = {}): ResourceControlSettings {
	return {
		enabled: true, mode: "auto", applyToBgTask: true, applyToAutoBackground: true,
		cpuWeight: 100, ioWeight: 100, nice: 10, ioniceClass: "best-effort",
		ioniceLevel: 7, warnOnFallback: true, ...overrides,
	};
}

export function probes(systemd: boolean, commands = ["nice", "ionice", "systemd-run", "systemctl"]): ResourceControlProbes {
	const available = new Set(commands);
	return {
		platform: "linux", commandExists: (command) => available.has(command),
		userSystemdAvailable: () => systemd,
	};
}

export function spawnInput(overrides: Partial<ResourceControlSpawnInput> = {}): ResourceControlSpawnInput {
	return {
		command, cwd: "/tmp/work tree", shell: "/bin/bash", shellArgs: ["-lc"],
		taskId: "bg-7", now: 123456, ...overrides,
	};
}
