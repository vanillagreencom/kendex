// Test extension: registers a tool that blocks for a configurable duration,
// giving the test harness time to inject messages via RPC while the tool
// handler is waiting for a result.
// The response text is a parsed test protocol: slow_tool_ms=<elapsed milliseconds>.
import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	const params = Type.Object({
		seconds: Type.Optional(Type.Number({ description: "How long to wait before returning (default 5)" })),
	});
	pi.registerTool<typeof params>({
		name: "SlowTool",
		label: "A tool that takes a while to return",
		description: "Waits for the specified number of seconds before returning. Use this when asked to call SlowTool.",
		parameters: params,
		async execute(_id, params, signal) {
			const delay = (params.seconds ?? 5) * 1000;
			await new Promise<void>((resolve, reject) => {
				const onAbort = () => {
					clearTimeout(timer);
					reject(new Error("tool_state=aborted"));
				};
				const timer = setTimeout(() => {
					signal?.removeEventListener("abort", onAbort);
					resolve();
				}, delay);
				if (signal?.aborted) onAbort();
				else signal?.addEventListener("abort", onAbort, { once: true });
			});
			return { content: [{ type: "text" as const, text: `slow_tool_ms=${delay}` }], details: {} };
		},
	});
}
