import * as piAi from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { hasCodexLogin, resolveCodexHome } from "./auth-presence.js";
import { CodexBridge } from "./bridge.js";
import { API_ID, buildPiModels, PROVIDER_ID } from "./models.js";
import { installSettingsCacheRefresh, readPackageConfig } from "./package-config.js";

const PACKAGE_ID = "@vanillagreen/pi-codex-bridge";
const OWNER = Symbol.for("pi-codex-bridge:provider-owner");
const globalState = globalThis as typeof globalThis & Record<PropertyKey, unknown>;

export default async function piCodexBridge(pi: ExtensionAPI): Promise<void> {
	installSettingsCacheRefresh(pi);
	if (readPackageConfig(PACKAGE_ID).enabled === false) return;
	// A nested Pi runtime in the same process keeps the first owner's provider.
	if (globalState[OWNER] !== undefined) return;

	const codexHome = resolveCodexHome();
	const bridge = new CodexBridge({ codexHome });
	globalState[OWNER] = bridge;
	let notice: string | undefined;
	let models: ReturnType<typeof buildPiModels> = [];
	if (hasCodexLogin(codexHome)) {
		const discovered = await bridge.discoverModels();
		models = buildPiModels(discovered.models);
		notice = discovered.notice;
	}

	pi.registerProvider(piAi.createProvider({
		id: PROVIDER_ID,
		name: "Pi Codex",
		baseUrl: API_ID,
		auth: {
			apiKey: {
				name: "Codex CLI login",
				check: async () => hasCodexLogin(codexHome) ? { type: "api_key" as const, source: "Codex CLI login" } : undefined,
				resolve: async () => hasCodexLogin(codexHome) ? { auth: {}, source: "Codex CLI login" } : undefined,
			},
		},
		models,
		api: { stream: bridge.streamSimple, streamSimple: bridge.streamSimple },
	}));
	pi.on("session_start", (_event, ctx) => {
		if (notice === undefined) return;
		const text = `${notice}\nPi Codex could not list Codex models, so none are offered. Run /reload to try again.`;
		if (ctx.hasUI) ctx.ui.notify(text, "warning");
		else process.stderr.write(`${text}\n`);
		notice = undefined;
	});
	pi.on("session_shutdown", async () => {
		await bridge.close();
		if (globalState[OWNER] === bridge) globalState[OWNER] = undefined;
	});
}
