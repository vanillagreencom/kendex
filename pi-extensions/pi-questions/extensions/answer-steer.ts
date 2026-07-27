// Opt-in mirror of answered questions into the conversation stream.
//
// Observer extensions (e.g. pi-automode) classify user messages but ignore
// tool output for security reasons, so answers returned only as tool results
// are invisible to them. When the answersAsUserMessage setting is enabled,
// each answered question is also delivered as one steer user message: the
// question quoted, the chosen answers below.

export interface AnswerSteerHost {
	sendUserMessage?: (content: string, options?: { deliverAs?: "steer" | "followUp" }) => unknown;
}

export type AnswerSteerRequest = { questions?: Array<{ header?: string; question?: string }> } | undefined;

export function formatAnswerSteerMessage(request: AnswerSteerRequest, answers: string[][]): string {
	const tabs = request?.questions ?? [];
	const count = Math.max(answers.length, tabs.length);
	const blocks: string[] = [];
	for (let index = 0; index < count; index += 1) {
		const tab = tabs[index];
		const question = tab?.question?.trim() || tab?.header?.trim() || `Question ${index + 1}`;
		const header = tab?.header?.trim() ?? "";
		const labelled = count > 1 && header && header !== question ? `${header}: ${question}` : question;
		const quoted = labelled.split("\n").map((line) => `> ${line.trim()}`.trimEnd()).join("\n");
		const tabAnswers = (answers[index] ?? []).map((answer) => answer.trim()).filter((answer) => answer.length > 0);
		blocks.push(`${quoted}\n\n${tabAnswers.length > 0 ? tabAnswers.join(", ") : "(no selection)"}`);
	}
	return blocks.join("\n\n");
}

export function emitAnswerSteer(host: AnswerSteerHost, request: AnswerSteerRequest, answers: string[][], onUndeliverable?: () => void): boolean {
	const send = host?.sendUserMessage;
	if (typeof send !== "function") {
		onUndeliverable?.();
		return false;
	}
	try {
		const outcome = send.call(host, formatAnswerSteerMessage(request, answers), { deliverAs: "steer" });
		if (outcome && typeof (outcome as { catch?: unknown }).catch === "function") {
			void (outcome as Promise<unknown>).catch(() => onUndeliverable?.());
		}
		return true;
	} catch {
		onUndeliverable?.();
		return false;
	}
}
