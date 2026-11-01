import * as piAi from "@earendil-works/pi-ai";

const dynamicImport = (specifier: string) => import(specifier);

export interface PiAiCompatDeps {
	root?: any;
	loadCompat?: () => Promise<any>;
}

type RetryAssistantCall = (
	produce: () => Promise<any>,
	policy: { enabled: boolean; maxRetries: number; baseDelayMs: number },
	signal: AbortSignal | undefined,
	callbacks?: {
		onRetryScheduled?: (attempt: number, maxAttempts: number, delayMs: number, errorMessage: string) => void | Promise<void>;
		onRetryAttemptStart?: () => void | Promise<void>;
		onRetryFinished?: (success: boolean, attempt: number, finalError?: string) => void | Promise<void>;
	},
) => Promise<any>;

async function dispatchCompletion(name: "complete" | "completeSimple", model: unknown, context: unknown, options: unknown, deps: PiAiCompatDeps): Promise<any> {
	const rootFunction = (deps.root ?? piAi as any)[name];
	if (typeof rootFunction === "function") return await rootFunction(model, context, options);
	const compat = deps.loadCompat ? await deps.loadCompat() : await dynamicImport("@earendil-works/pi-ai/compat") as any;
	return await compat[name](model, context, options);
}

export async function complete(model: unknown, context: unknown, options?: unknown, deps: PiAiCompatDeps = {}): Promise<any> {
	return await dispatchCompletion("complete", model, context, options, deps);
}

export async function completeSimple(model: unknown, context: unknown, options?: unknown, deps: PiAiCompatDeps = {}): Promise<any> {
	return await dispatchCompletion("completeSimple", model, context, options, deps);
}

// The lowest reasoning level the model accepts, as `SimpleStreamOptions.reasoning`
// takes it. Simple options express "off" by leaving the level out, so a model that
// can turn reasoning off gets undefined. Levels come from pi-ai's model catalog.
export function lowestReasoningLevel(model: unknown, deps: { root?: any } = {}): string | undefined {
	const [lowest] = (deps.root ?? piAi as any).getSupportedThinkingLevels(model) as string[];
	return lowest === "off" ? undefined : lowest;
}

export async function retryAssistantCallCompat(
	produce: () => Promise<any>,
	signal: AbortSignal | undefined,
	callbacks?: Parameters<RetryAssistantCall>[3],
	deps: { root?: any } = {},
): Promise<any> {
	const candidate = (deps.root ?? piAi as any).retryAssistantCall as RetryAssistantCall | undefined;
	if (typeof candidate !== "function") return produce();
	return candidate(produce, { enabled: true, maxRetries: 3, baseDelayMs: 2000 }, signal, callbacks);
}