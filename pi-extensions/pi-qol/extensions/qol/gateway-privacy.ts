import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { recordProjectTrust } from "./package-config.js";
import { settingBoolean } from "./settings.js";

function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

function gatewayPrivacyCovers(model: { provider: string } | undefined, cwd: string): boolean {
	const provider = model?.provider;
	return (provider === "openrouter" || provider === "vercel-ai-gateway") && settingBoolean("gatewayPrivacy.enabled", false, cwd);
}

/** Pi sends its own compaction and branch summaries to the session model with
 * no payload callback, so for a covered model QOL writes the summary and never
 * falls back to Pi's. */
export function gatewayPrivacyBlocksNativeSummary(ctx: ExtensionContext): boolean {
	recordProjectTrust(ctx);
	return gatewayPrivacyCovers(ctx.model, ctx.cwd);
}

export function gatewayPrivacyOnPayload(ctx: ExtensionContext): (payload: unknown, model: { provider: string } | undefined) => unknown {
	const cwd = ctx.cwd;
	recordProjectTrust(ctx);
	return (payload, model) => {
		if (!gatewayPrivacyCovers(model, cwd)) return undefined;
		const body = payload;
		if (!isRecord(body)) return undefined;

		// These request filters are opt-in package policy. Caller routing keys
		// remain, but weaker privacy values must not disable an enabled filter.
		if (model?.provider === "openrouter") {
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
	};
}

export function registerGatewayPrivacy(pi: ExtensionAPI): void {
	pi.on("before_provider_request", (event, ctx) => gatewayPrivacyOnPayload(ctx)(event.payload, ctx.model));
}
