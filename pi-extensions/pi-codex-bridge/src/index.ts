import * as piAi from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { hasCodexLogin, LOGIN_MISSING_KEY, resolveCodexHome } from "./auth-presence.js";
import { CodexBridge } from "./bridge.js";
import { API_ID, buildPiModels, PROVIDER_ID } from "./models.js";
import {
	installSettingsCacheRefresh,
	projectSettingsPath,
	readPackageConfig,
	readPackageConfigAt,
	recordProjectTrust,
	userAndProjectSettingsPaths,
} from "./package-config.js";

const PACKAGE_ID = "@vanillagreen/pi-codex-bridge";
const OWNER = Symbol.for("pi-codex-bridge:provider-owner");
const globalState = globalThis as typeof globalThis & Record<PropertyKey, unknown>;

/** Whether the package is enabled however Pi answers project trust. The
 * project file is read untrusted only to withhold the provider, never to
 * enable it. */
function enabledWhateverTrust(cwd: string): boolean {
	return [undefined, projectSettingsPath(cwd)].every((project) => readPackageConfigAt(PACKAGE_ID, userAndProjectSettingsPaths(project)).enabled !== false);
}

export default async function piCodexBridge(pi: ExtensionAPI): Promise<void> {
	installSettingsCacheRefresh(pi);
	// A nested Pi runtime in the same process keeps the first owner's provider.
	if (globalState[OWNER] !== undefined) return;

	const codexHome = resolveCodexHome();
	const bridge = new CodexBridge({ codexHome });
	globalState[OWNER] = bridge;
	let notice: string | undefined;
	let active = false;

	/** Discover the account's models and register the provider. */
	const activate = async (): Promise<void> => {
		active = true;
		let models: ReturnType<typeof buildPiModels> = [];
		if (hasCodexLogin(codexHome)) {
			const discovered = await bridge.discoverModels();
			models = buildPiModels(discovered.models);
			if (discovered.notice !== undefined) notice = `${discovered.notice}\nPi Codex could not list Codex models, so none are offered. Run /reload to try again.`;
		} else {
			notice = `${LOGIN_MISSING_KEY} home=${codexHome}\nPi Codex offers no models until the Codex CLI is signed in: codex login`;
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
	};

	// Pi gives a factory no trust answer: packages record it at session_start.
	// Startup model selection reads only providers the factory registered, so
	// the factory activates when no trust answer can disable the package, and
	// session_start decides the rest once trust is recorded.
	if (enabledWhateverTrust(process.cwd())) await activate();
	pi.on("session_start", async (_event, ctx) => {
		recordProjectTrust(ctx);
		if (!active && readPackageConfig(PACKAGE_ID, ctx.cwd).enabled !== false) await activate();
		if (notice === undefined) return;
		if (ctx.hasUI) ctx.ui.notify(notice, "warning");
		else process.stderr.write(`${notice}\n`);
		notice = undefined;
	});
	pi.on("session_shutdown", async () => {
		await bridge.close();
		if (globalState[OWNER] === bridge) globalState[OWNER] = undefined;
	});
}
