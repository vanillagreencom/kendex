import { expect, test } from "bun:test";
import { claudeSessionSource, claudeToolName } from "../extensions/vocab.ts";

for (const [reason, source] of [
	["startup", "startup"], ["resume", "resume"], ["reload", "resume"], ["new", "clear"], ["fork", "clear"],
]) test(`session reason ${reason}`, () => { expect(claudeSessionSource(reason)).toBe(source); });

for (const [tool, name] of [
	["bash", "Bash"], ["read", "Read"], ["write", "Write"], ["edit", "Edit"], ["grep", "Grep"], ["find", "Glob"], ["ls", "LS"], ["powershell", "powershell"],
]) test(`tool name ${tool}`, () => { expect(claudeToolName(tool)).toBe(name); });
