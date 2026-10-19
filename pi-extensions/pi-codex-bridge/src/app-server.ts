import { execFile, spawn as nodeSpawn, type ChildProcessWithoutNullStreams, type SpawnOptionsWithoutStdio } from "node:child_process";
import { promisify } from "node:util";
import { appServerArgs, SUPPORTED_CODEX_VERSION } from "./codex-policy.js";
import { codexChildEnvironment } from "./codex-environment.js";
import { CodexProtocolClient, type ProtocolClient } from "./json-rpc.js";
import { decodeModelPage, decodeVersion, type CodexModel } from "./protocol.js";

const execFileAsync = promisify(execFile);

export type SpawnFunction = (command: string, args: readonly string[], options: SpawnOptionsWithoutStdio) => ChildProcessWithoutNullStreams;

/** Everything one app-server launch needs. */
export interface Launch {
	executable: string;
	codexHome: string;
	cwd: string;
	env: NodeJS.ProcessEnv;
	/** Test seam: extra `-c` overrides, such as a local mock model provider. The
	 * extension factory never sets it. */
	configOverrides: readonly string[];
}

export const INITIALIZE_PARAMS = {
	clientInfo: {
		name: "pi_codex_bridge",
		title: "Pi Codex bridge",
		version: "1.0.0",
	},
	capabilities: {
		experimentalApi: true,
		requestAttestation: false,
	},
};

export async function assertSupportedCodex(launch: Launch): Promise<void> {
	let stdout: string;
	try {
		({ stdout } = await execFileAsync(launch.executable, ["--version"], {
			env: codexChildEnvironment(launch.codexHome, launch.env),
			encoding: "utf8",
			maxBuffer: 4096,
			timeout: 10_000,
		}));
	} catch (error) {
		throw new Error(`codex-version-unreadable executable=${launch.executable} code=${(error as NodeJS.ErrnoException).code ?? "unknown"}`);
	}
	const found = decodeVersion(stdout);
	if (found !== SUPPORTED_CODEX_VERSION) {
		throw new Error(`codex-version-unsupported found=${found} expected=${SUPPORTED_CODEX_VERSION}`);
	}
}

/** Start one `codex app-server` child and complete the handshake. */
export async function startAppServer(launch: Launch, spawn: SpawnFunction = nodeSpawn): Promise<ProtocolClient> {
	await assertSupportedCodex(launch);
	// Its own process group, so a breach stops the MCP servers it started too.
	const group = process.platform !== "win32";
	const child = spawn(launch.executable, appServerArgs(launch.configOverrides), {
		cwd: launch.cwd,
		env: codexChildEnvironment(launch.codexHome, launch.env),
		detached: group,
		windowsHide: true,
	});
	const client = new CodexProtocolClient(child, group);
	await client.request("initialize", INITIALIZE_PARAMS);
	client.notify("initialized");
	return client;
}

export async function listCodexModels(client: ProtocolClient): Promise<CodexModel[]> {
	const models: CodexModel[] = [];
	let cursor: string | null = null;
	do {
		const page: { models: CodexModel[]; nextCursor: string | null } = await client.requestDecoded("model/list", { includeHidden: false, ...(cursor === null ? {} : { cursor }) }, decodeModelPage);
		models.push(...page.models);
		cursor = page.nextCursor;
	} while (cursor !== null);
	return models;
}
