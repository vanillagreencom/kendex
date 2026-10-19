// A login-free world for the real Codex 0.163.0 app-server: a scratch
// CODEX_HOME whose user config declares one marker MCP server and trusts a
// scratch project that declares another, a mock model provider on 127.0.0.1,
// and a spawn seam that records every child the bridge starts.
import { spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { startAppServer } from "../../src/app-server.ts";
import { CodexBridge } from "../../src/bridge.ts";
import { startMockResponses } from "./mock-responses.mjs";

const packageDir = fileURLToPath(new URL("../..", import.meta.url));
export const CODEX = join(packageDir, "node_modules", "@openai", "codex", "bin", "codex.js");
export const ENV_SENTINEL = "SENTINEL-ENV-7f3a1658";
export const ARG_SENTINEL = "SENTINEL-ARG-9c2e1658";

const markerScript = join(packageDir, "tests", "fixtures", "marker-mcp.mjs");

function serverTable(name, marker) {
	return [
		`[mcp_servers.${name}]`,
		`command = ${JSON.stringify(process.execPath)}`,
		`args = [${JSON.stringify(markerScript)}, ${JSON.stringify(marker)}, "--token", ${JSON.stringify(ARG_SENTINEL)}]`,
		`env = { FIXTURE_TOKEN = ${JSON.stringify(ENV_SENTINEL)} }`,
		"",
	].join("\n");
}

export async function fixtureWorld(name, { script = [], model = "gpt-5.5", userConfig = "" } = {}) {
	const scratch = join(packageDir, "tmp");
	mkdirSync(scratch, { recursive: true });
	const root = mkdtempSync(join(scratch, `fixture-${name}-`));
	const home = join(root, "codex-home");
	const project = join(root, "project");
	mkdirSync(home);
	mkdirSync(join(project, ".git"), { recursive: true });
	mkdirSync(join(project, ".codex"));
	const markers = { user: join(root, "STARTED-user"), project: join(root, "STARTED-project"), late: join(root, "STARTED-late") };
	// A fixture API key: Codex never sends it, because the mock provider
	// requires no OpenAI auth. It exists so the bridge's login check passes.
	writeFileSync(join(home, "auth.json"), JSON.stringify({ OPENAI_API_KEY: "sk-fixture-not-a-credential" }));
	const homeConfig = join(home, "config.toml");
	writeFileSync(homeConfig, `${userConfig}\n${serverTable("user_marker", markers.user)}\n[projects.${JSON.stringify(project)}]\ntrust_level = "trusted"\n`);
	const projectConfig = join(project, ".codex", "config.toml");
	writeFileSync(projectConfig, serverTable("project_marker", markers.project));

	const mock = await startMockResponses(script);
	const configOverrides = [
		'model_provider="mock"',
		`model_providers.mock={name="mock",base_url="http://127.0.0.1:${mock.port}/v1",wire_api="responses",requires_openai_auth=false,request_max_retries=0,stream_max_retries=0}`,
	];
	const children = [];
	const sentLines = [];
	/** Called with each JSON-RPC line the bridge writes, before Codex reads it. */
	let beforeWrite = () => undefined;
	const recordingSpawn = (command, args, options) => {
		const child = spawn(command, args, options);
		children.push({ command, args: [...args], env: { ...options.env }, child });
		const write = child.stdin.write.bind(child.stdin);
		child.stdin.write = (chunk, ...rest) => {
			const line = chunk.toString();
			sentLines.push(line);
			beforeWrite(line);
			return write(chunk, ...rest);
		};
		return child;
	};
	const newBridge = () => new CodexBridge({
		codexHome: home,
		cwd: project,
		executable: CODEX,
		configOverrides,
		connect: (launch) => startAppServer(launch, recordingSpawn),
	});
	return {
		root,
		home,
		project,
		homeConfig,
		projectConfig,
		markers,
		mock,
		children,
		model,
		newBridge,
		onWrite: (hook) => (beforeWrite = hook),
		sentMethods: () => sentLines.flatMap((line) => line.split("\n").filter(Boolean)).map((line) => JSON.parse(line).method).filter(Boolean),
		addLateServer: () => appendFileSync(homeConfig, `\n${serverTable("late_marker", markers.late)}`),
		startedMarkers: () => Object.entries(markers).filter(([, path]) => existsSync(path)).map(([key]) => key),
		async close() {
			await mock.close();
			for (const { child } of children) {
				if (child.exitCode === null && child.signalCode === null) {
					child.kill("SIGKILL");
					await new Promise((resolve) => child.once("exit", resolve));
				}
			}
			rmSync(root, { recursive: true, force: true });
		},
	};
}

/** Every file under `dir` whose bytes hold `needle`, `skip` excepted. */
export function filesHolding(dir, needle, skip = []) {
	const hits = [];
	const walk = (path) => {
		for (const entry of readdirSync(path, { withFileTypes: true })) {
			const full = join(path, entry.name);
			if (entry.isSymbolicLink()) continue;
			if (entry.isDirectory()) walk(full);
			else if (entry.isFile() && !skip.includes(full) && statSync(full).size < 64 * 1024 * 1024 && readFileSync(full).includes(needle)) hits.push(full);
		}
	};
	walk(dir);
	return hits;
}

export function piModel(id) {
	return {
		id,
		name: id,
		api: "codex-app-server",
		provider: "pi-codex",
		baseUrl: "codex-app-server",
		reasoning: false,
		input: ["text"],
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		contextWindow: 128000,
		maxTokens: 32000,
	};
}
