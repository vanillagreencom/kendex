import * as piAi from "@earendil-works/pi-ai";

const dynamicImport = (specifier: string) => import(specifier);

export interface PiAiCompatDeps {
	root?: any;
	loadCompat?: () => Promise<any>;
}

export async function complete(model: unknown, context: unknown, options?: unknown, deps: PiAiCompatDeps = {}): Promise<any> {
	const rootComplete = (deps.root ?? piAi as any).complete;
	if (typeof rootComplete === "function") return await rootComplete(model, context, options);
	const compat = deps.loadCompat ? await deps.loadCompat() : await dynamicImport("@earendil-works/pi-ai/compat") as any;
	return await compat.complete(model, context, options);
}