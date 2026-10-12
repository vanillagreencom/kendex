import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { recordProjectTrust } from "./package-config.js";
import { settingBoolean } from "./settings.js";

function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function registerGatewayPrivacy(pi: ExtensionAPI): void {
	pi.on("before_provider_request", (event, ctx) => {
		const provider = ctx.model?.provider;
		if (provider !== "openrouter" && provider !== "vercel-ai-gateway") return undefined;
		recordProjectTrust(ctx);
		if (!settingBoolean("gatewayPrivacy.enabled", false, ctx.cwd)) return undefined;
		const body = event.payload;
		if (!isRecord(body)) return undefined;

		// These request filters are opt-in package policy. Caller routing keys
		// remain, but weaker privacy values must not disable an enabled filter.
		if (provider === "openrouter") {
			return {
				...body,
				provider: {
					...(isRecord(body.provider) ? body.provider : {}),
					zdr: true,
					data_collection: "deny",
				},
			};
		}
		const options = isRecord(body.providerOptions) ? body.providerOptions : {};
		return {
			...body,
			providerOptions: {
				...options,
				gateway: {
					...(isRecord(options.gateway) ? options.gateway : {}),
					zeroDataRetention: true,
					disallowPromptTraining: true,
				},
			},
		};
	});
}
