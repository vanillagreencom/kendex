import type { ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { PACKAGE_TAB_PREFIX, type ApplyMode, type SettingsSchema, type TopTab } from "./types.js";

const ANSI_GREEN_FG = "\x1b[32m";
const ANSI_YELLOW_FG = "\x1b[33m";
const ANSI_RED_FG = "\x1b[31m";
const ANSI_FG_RESET = "\x1b[39m";
const MANAGER_NOTICE_PREFIX = "pi-extension-manager: ";

export function ansiGreen(text: string): string { return `${ANSI_GREEN_FG}${text}${ANSI_FG_RESET}`; }
export function ansiYellow(text: string): string { return `${ANSI_YELLOW_FG}${text}${ANSI_FG_RESET}`; }
export function ansiRed(text: string): string { return `${ANSI_RED_FG}${text}${ANSI_FG_RESET}`; }

/** Stable notification header; explanation remains free to change. */
export function managerNotice(key: string, value: string | number, explanation: string): string {
	const shown = String(value).replace(/[\u0000-\u001f\u007f]/g, "?");
	return `${MANAGER_NOTICE_PREFIX}${key}=${shown}\n${explanation}`;
}

export function stringifyError(error: unknown): string {
	if (error instanceof Error) return `${error.name}: ${error.message}`;
	return String(error);
}

/** Preserve a specific manager refusal when a UI boundary catches it. */
export function managerFailure(key: string, value: string | number, error: unknown): string {
	if (error instanceof Error && error.message.startsWith(MANAGER_NOTICE_PREFIX)) return error.message;
	return managerNotice(key, value, stringifyError(error));
}

export function isPlainSearchInput(data: string): boolean {
	return data.length === 1 && data >= " " && data !== "\x7f";
}

export function kindLabel(kind: string): string {
	return kind === "extension module" ? "module" : kind.replace(" command", " cmd");
}

export function scopeFilterLabel(value: string): string {
	return value === "temporary" ? "tmp" : value;
}

export function packageTabId(packageName: string): TopTab {
	return `${PACKAGE_TAB_PREFIX}${packageName}`;
}

export function packageNameForTab(tab: TopTab): string | undefined {
	return tab.startsWith(PACKAGE_TAB_PREFIX) ? tab.slice(PACKAGE_TAB_PREFIX.length) : undefined;
}

export function parseSettingInput(schema: SettingsSchema, input: string): unknown {
	switch (schema.type) {
		case "boolean": {
			const lower = input.trim().toLowerCase();
			if (["true", "yes", "on", "1", "enabled"].includes(lower)) return true;
			if (["false", "no", "off", "0", "disabled"].includes(lower)) return false;
			throw new Error(managerNotice("setting-boolean", schema.key, "Expected boolean: true/false, on/off, yes/no"));
		}
		case "number": {
			const parsed = Number(input.trim());
			if (!Number.isFinite(parsed)) throw new Error(managerNotice("setting-number", schema.key, "Expected a number"));
			return parsed;
		}
		case "enum": {
			const value = input.trim();
			if (schema.enumValues?.length && !schema.enumValues.includes(value)) {
				throw new Error(managerNotice("setting-enum", schema.key, `Expected one of: ${schema.enumValues.join(", ")}`));
			}
			return value;
		}
		case "secret":
		case "path":
		case "string":
			return input;
	}
}

export function nextSettingValue(schema: SettingsSchema, current: unknown): unknown {
	if (schema.type === "boolean") return !(current === true);
	if (schema.type === "enum" && schema.enumValues?.length) {
		const idx = schema.enumValues.indexOf(String(current ?? schema.default ?? ""));
		return schema.enumValues[(idx + 1 + schema.enumValues.length) % schema.enumValues.length];
	}
	return current;
}

export function formatSettingValue(schema: SettingsSchema, value: unknown): string {
	if (schema.secret) return value == null || value === "" ? "(unset)" : "••••••";
	if (value === undefined) return "(unset)";
	if (typeof value === "object") return JSON.stringify(value);
	return String(value);
}

export function stringifySettingValue(value: unknown): string {
	if (value === undefined || value === null) return "";
	if (typeof value === "boolean") return value ? "true" : "false";
	if (typeof value === "object") return JSON.stringify(value);
	return String(value);
}

function applyOf(schema: SettingsSchema): ApplyMode {
	return schema.apply ?? (schema.requiresReload ? "reload" : "live");
}

export function hasDeferredApply(schemas: SettingsSchema[]): boolean {
	return schemas.some((schema) => applyOf(schema) !== "live");
}

export function applyMessage(schema: SettingsSchema): string {
	const apply = applyOf(schema);
	if (apply === "live") return managerNotice("setting-saved", `${schema.key}:${apply}`, "Setting saved and available to extensions immediately.");
	if (apply === "reload") return managerNotice("setting-saved", `${schema.key}:${apply}`, "Setting saved. Run /reload for extensions that read it at load time.");
	if (apply === "session") return managerNotice("setting-saved", `${schema.key}:${apply}`, "Setting saved. Start/resume a session to fully apply it.");
	return managerNotice("setting-saved", `${schema.key}:${apply}`, "Setting saved. Restart Pi to fully apply it.");
}

export function notifyReset(ctx: ExtensionCommandContext | ExtensionContext, label: string, schemas: SettingsSchema[]): void {
	ctx.ui.notify(managerNotice("settings-reset", schemas.map((schema) => schema.key).join(","), `${label} reset to default${schemas.length === 1 ? "" : "s"}.${hasDeferredApply(schemas) ? " Reload/restart may be required for deferred settings." : ""}`), hasDeferredApply(schemas) ? "warning" : "info");
}
