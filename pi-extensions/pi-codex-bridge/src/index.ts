import * as piAi from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { listCodexModels, startAppServer } from "./app-server.js";
import { hasCodexLogin, requireCodexLogin, resolveCodexHome } from "./auth-presence.js";
import { CodexBridge } from "./bridge.js";
import { buildPiModels } from "./models.js";
import { installSettingsCacheRefresh, readPackageConfig } from "./package-config.js";

const PACKAGE_ID = "@vanillagreen/pi-codex-bridge";
const OWNER = Symbol.for("pi-codex-bridge:provider-owner");
const globalState = globalThis as typeof globalThis & Record<PropertyKey, unknown>;

export default async function piCodexBridge(pi: ExtensionAPI): Promise<void> {
	installSettingsCacheRefresh(pi);
	if (readPackageConfig(PACKAGE_ID).enabled === false) return;
	if (globalState[OWNER] !== undefined) return;
	globalState[OWNER] = true;

	const codexHome = resolveCodexHome();
	const bridge = new CodexBridge({ codexHome });
	try {
		let models: ReturnType<typeof buildPiModels> = [];
		if (hasCodexLogin(codexHome)) {
			const discovery = await startAppServer(bridge.executable, codexHome);
			try {
				models = buildPiModels(await listCodexModels(discovery));
			} finally {
				discovery.close();
			}
		}

		const guardedStream = (...args: Parameters<typeof bridge.streamSimple>) => {
			requireCodexLogin(codexHome);
			return bridge.streamSimple(...args);
		};
		const provider = piAi.createProvider({
			id: "pi-codex",
			name: "Pi Codex",
			baseUrl: "codex-app-server",
			auth: {
				apiKey: {
					name: "Codex CLI login",
					check: async () => hasCodexLogin(codexHome)
						? { type: "api_key" as const, source: "Codex CLI login" }
						: undefined,
					resolve: async () => hasCodexLogin(codexHome)
						? { auth: {}, source: "Codex CLI login" }
						: undefined,
				},
			},
			models,
			api: {
				stream: guardedStream,
				streamSimple: guardedStream,
			},
		});
		pi.registerProvider(provider);
		pi.on("session_shutdown", async () => {
			await bridge.close();
			if (globalState[OWNER] === bridge) globalState[OWNER] = undefined;
		});
		globalState[OWNER] = bridge;
	} catch (error) {
		globalState[OWNER] = undefined;
		await bridge.close();
		throw error;
	}
}
