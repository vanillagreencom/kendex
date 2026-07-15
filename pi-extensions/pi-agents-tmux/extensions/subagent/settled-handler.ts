export interface SettledLifecycleRegistrar {
	on(event: "agent_settled", handler: (event: unknown, ctx: any) => void | Promise<void>): void;
}

export function registerSettledHandler(
	pi: SettledLifecycleRegistrar,
	handler: (ctx: any) => void | Promise<void>,
): void {
	pi.on("agent_settled", async (_event, ctx) => {
		await handler(ctx);
	});
}