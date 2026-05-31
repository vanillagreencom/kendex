export const DEFAULT_CUSTOM_LABEL = "Something else";
export const DEFAULT_CUSTOM_PLACEHOLDER = "Type your answer, then press enter.";

export interface QuestionOption {
	label: string;
	description: string;
}

export interface QuestionTab {
	header: string;
	question: string;
	options: QuestionOption[];
	multiple: boolean;
	allowCustom: boolean;
	customLabel: string;
	customPlaceholder: string;
}

export interface QuestionRequest {
	id: string;
	header: string;
	questions: QuestionTab[];
}

function makeRequestId(): string {
	return `que_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
}

function asRecord(value: unknown, name: string): Record<string, unknown> {
	if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${name} must be an object`);
	return value as Record<string, unknown>;
}

function readString(value: unknown, fallback: string): string {
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
}

export function questionRowCount(question: QuestionTab): number {
	return question.options.length + (question.allowCustom ? 1 : 0);
}

export function isQuestionCustomRow(question: QuestionTab, index: number): boolean {
	return question.allowCustom && index === question.options.length;
}

export function normalizeRequest(payload: unknown): QuestionRequest {
	const input = asRecord(payload, "question request");
	const rawQuestions = input.questions;
	if (!Array.isArray(rawQuestions) || rawQuestions.length === 0) throw new Error("questions must be a non-empty array");

	const questions = rawQuestions.map((rawQuestion, index) => {
		const question = asRecord(rawQuestion, `questions[${index}]`);
		const rawOptions = question.options;
		if (!Array.isArray(rawOptions) || rawOptions.length === 0) {
			throw new Error(`questions[${index}].options must be a non-empty array`);
		}

		const seen = new Set<string>();
		const options = rawOptions.map((rawOption, optionIndex) => {
			const option = asRecord(rawOption, `questions[${index}].options[${optionIndex}]`);
			const label = readString(option.label, "");
			if (!label) throw new Error(`questions[${index}].options[${optionIndex}].label is required`);
			if (seen.has(label)) throw new Error(`Duplicate option label in questions[${index}]: ${label}`);
			seen.add(label);
			return {
				description: typeof option.description === "string" ? option.description : "",
				label,
			};
		});

		return {
			allowCustom: true,
			customLabel: readString(question.customLabel, DEFAULT_CUSTOM_LABEL),
			customPlaceholder: readString(question.customPlaceholder, DEFAULT_CUSTOM_PLACEHOLDER),
			header: readString(question.header, `Question ${index + 1}`),
			multiple: question.multiple === true,
			options,
			question: readString(question.question, "Choose an option."),
		};
	});

	const id = readString(input.id, makeRequestId());
	const firstHeader = questions[0]?.header ?? "Question";
	return {
		header: readString(input.header ?? input.title, firstHeader),
		id,
		questions,
	};
}

export function normalizeAnswers(request: QuestionRequest, rawAnswers: unknown): string[][] {
	if (!Array.isArray(rawAnswers)) throw new Error("answers must be an array of per-tab label arrays");
	if (rawAnswers.length !== request.questions.length) {
		throw new Error(`answers length (${rawAnswers.length}) must match questions length (${request.questions.length})`);
	}

	return request.questions.map((question, index) => {
		const rawTabAnswers = rawAnswers[index];
		if (!Array.isArray(rawTabAnswers)) throw new Error(`answers[${index}] must be an array`);
		const valid = new Set(question.options.map((option) => option.label));
		const unique: string[] = [];
		for (const rawLabel of rawTabAnswers) {
			if (typeof rawLabel !== "string") throw new Error(`answers[${index}] entries must be strings`);
			const label = rawLabel.trim();
			if (!label) continue;
			if (!valid.has(label) && !question.allowCustom) throw new Error(`answers[${index}] contains invalid label: ${label}`);
			if (!unique.includes(label)) unique.push(label);
		}
		if (!question.multiple && unique.length > 1) {
			throw new Error(`answers[${index}] accepts only one label because multiple=false`);
		}
		return unique;
	});
}
