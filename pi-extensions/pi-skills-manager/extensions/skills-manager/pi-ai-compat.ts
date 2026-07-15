import * as piAi from "@earendil-works/pi-ai";

const dynamicImport = (specifier: string) => import(specifier);

export async function completeSimple(
	model: unknown,
	context: unknown,
	options?: unknown,
	deps: { root?: any; loadCompat?: () => Promise<any> } = {},
): Promise<any> {
	const rootCompleteSimple = (deps.root ?? piAi as any).completeSimple;
	if (typeof rootCompleteSimple === "function") return await rootCompleteSimple(model, context, options);
	const compat = deps.loadCompat ? await deps.loadCompat() : await dynamicImport("@earendil-works/pi-ai/compat") as any;
	return await compat.completeSimple(model, context, options);
}