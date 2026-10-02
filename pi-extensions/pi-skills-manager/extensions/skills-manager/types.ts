import type { ThinkingLevel } from "@earendil-works/pi-ai";

export type OverlaySize = number | `${number}%` | string;
export type ExtensionInstallScope = "global" | "project";
export type SkillScope = "user" | "project" | "temporary";
export type SkillOrigin = "package" | "top-level";
export type SkillLocation = "project" | "global";
export type MessageTone = "dim" | "success" | "error";
export type Mode = "browse" | "create" | "preview" | "edit" | "rename" | "delete-confirm" | "deleting" | "generating";

export interface kendexModalLock {
	depth: number;
}

export type CreateTextStepId = "name" | "description";
export type CreateChoiceStepId = "location";
export type CreateStepId = CreateTextStepId | CreateChoiceStepId;

/** One skill in the inventory. The body is not held here: the preview reads
 *  it from `path` for the one skill it shows. */
export interface SkillEntry {
	name: string;
	description: string;
	path: string;
	frontmatter?: Record<string, unknown>;
	scope: SkillScope;
	origin: SkillOrigin;
	source: string;
	baseDir?: string;
	enabled: boolean;
}

export interface SkillRegistry {
	skills: SkillEntry[];
	allSkills: SkillEntry[];
	byName: Map<string, SkillEntry>;
}

export interface SkillCreationAnswers {
	name: string;
	description: string;
	exampleRequests?: string;
	domainContext?: string;
	allowedTools: string[];
	location: SkillLocation;
}

export interface SkillGenerationOptions {
	thinkingLevel?: ThinkingLevel | "off";
	signal?: AbortSignal;
}

export interface ParsedSkillDocument {
	name: string;
	description: string;
	frontmatter: Record<string, unknown>;
	content: string;
	raw: string;
}

export interface SettingsFile {
	path: string;
	json: Record<string, unknown>;
	exists: boolean;
}

export interface CreateTextStep {
	id: CreateTextStepId;
	title: string;
	hint: string;
	kind: "text";
	optional: boolean;
}

export interface CreateChoiceOption {
	value: SkillLocation;
	label: string;
	description: string;
}

export interface CreateChoiceStep {
	id: CreateChoiceStepId;
	title: string;
	hint: string;
	kind: "choice";
	optional: boolean;
	options: CreateChoiceOption[];
}

export type CreateStep = CreateTextStep | CreateChoiceStep;

export interface SkillsManagerOptions {
	onCreate: (answers: SkillCreationAnswers, signal?: AbortSignal) => Promise<SkillEntry | null>;
	onDelete: (skill: SkillEntry) => Promise<boolean>;
	onToggle: (skill: SkillEntry, enabled: boolean) => Promise<void>;
	onRefresh: () => Promise<SkillRegistry>;
}

export const LOCATION_OPTIONS: CreateChoiceOption[] = [
	{ value: "project", label: "Project", description: "Save in this project's .pi/skills directory." },
	{ value: "global", label: "Global", description: "Save in your user-level Pi skills directory." },
];

export const CREATE_STEPS: CreateStep[] = [
	{ id: "name", title: "Name", hint: "Use lowercase letters, numbers, and hyphens, for example react-review.", optional: false, kind: "text" },
	{ id: "description", title: "Description", hint: "Describe what the skill does and when it should be used. Specific trigger language works best.", optional: false, kind: "text" },
	{ id: "location", title: "Visibility", hint: "Choose whether the skill is project-local or available in all Pi sessions.", optional: false, kind: "choice", options: LOCATION_OPTIONS },
];
