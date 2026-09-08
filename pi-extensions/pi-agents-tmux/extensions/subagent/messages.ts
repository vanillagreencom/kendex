import type { AgentConfig } from "./agents.js";

export function messageRecord(key: string, value: string): string {
	const singleLineValue = JSON.stringify(value).slice(1, -1);
	return `${key}=${singleLineValue}`;
}

export function unknownAgentRefusal(agentName: string, agents: readonly Pick<AgentConfig, "name">[]): string {
	const available = agents.map((agent) => `"${agent.name}"`).join(", ") || "none";
	return [
		messageRecord("unknown_agent", agentName),
		`Unknown agent: "${agentName}". Available agents: ${available}.`,
	].join("\n");
}

export function livePaneRefusal(agentName: string, windowName: string): string {
	return [
		messageRecord("pane_already_running", agentName),
		`Cannot forceSpawn ${agentName}: a live pane already exists for this agent.`,
		"kendex does not support multiple live panes for the same agent. Either:",
		`  - Drop forceSpawn and the call will reuse the existing pane (queue this task into ${windowName}), or`,
		`  - Use stop_subagent or /agents stop ${agentName} first, then retry with forceSpawn for a fresh session.`,
	].join("\n");
}

export function piBridgeResolverNotice(status: "failed" | "missing", reason: string): string {
	return [
		messageRecord("pi_bridge_resolver", status),
		`Pi bridge resolver failed: ${reason}`,
	].join("\n");
}
