import { expect, test } from "bun:test";
import { claudeSessionEndReason, claudeSessionSource, claudeToolName, PI_BUILTIN_TOOLS, PI_SESSION_REASONS } from "../extensions/vocab.ts";

const sessions = [
	["startup", "startup"], ["resume", "resume"], ["reload", "resume"], ["new", "clear"], ["fork", "clear"],
] as const;
const endings = [
	["quit", "prompt_input_exit"], ["new", "clear"], ["fork", "clear"], ["resume", "resume"], ["reload", "resume"],
] as const;
const tools = [
	["bash", "Bash"], ["read", "Read"], ["write", "Write"], ["edit", "Edit"], ["grep", "Grep"], ["find", "Glob"], ["ls", "LS"], ["powershell", "powershell"],
] as const;

for (const [reason, source] of sessions) test(`session reason ${reason}`, () => { expect(claudeSessionSource(reason)).toBe(source); });
for (const [reason, said] of endings) test(`session end reason ${reason}`, () => { expect(claudeSessionEndReason(reason)).toBe(said); });
for (const [tool, name] of tools) test(`tool name ${tool}`, () => { expect(claudeToolName(tool)).toBe(name); });

// The changelog publishes these named exports for extension consumers.
for (const row of [
	{ name: "session reasons", actual: PI_SESSION_REASONS, expected: sessions.map(([reason]) => reason) },
	{ name: "built-in tools", actual: PI_BUILTIN_TOOLS, expected: tools.map(([tool]) => tool) },
]) test(`public vocabulary: ${row.name}`, () => { expect([...row.actual].sort()).toEqual([...row.expected].sort()); });
