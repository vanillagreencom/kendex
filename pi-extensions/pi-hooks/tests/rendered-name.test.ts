import { expect, test } from "bun:test";
import { renderedName } from "../extensions/registry.ts";
import { projectCommand } from "./harness.ts";

for (const row of [
	{ name: "global", root: "/x/.pi/kendex", command: 'bash "/x/.pi/kendex/hooks/guard.sh"', anchor: undefined, expected: "guard" },
	{ name: "project", root: "/x/.pi/kendex", command: projectCommand(".pi/kendex/hooks/guard.sh"), anchor: "/x", expected: "guard" },
	{ name: "project without anchor", root: "/x/.pi/kendex", command: projectCommand(".pi/kendex/hooks/guard.sh"), anchor: undefined, expected: "" },
	{ name: "foreign root", root: "/x/.pi/kendex", command: 'bash "/opt/kendex/hooks/guard.sh"', anchor: undefined, expected: "" },
	{ name: "outside hooks", root: "/x/.pi/kendex", command: projectCommand(".pi/kendex/guard.sh"), anchor: "/x", expected: "" },
	{ name: "normalized global", root: "/srv/pi-agent/kendex", command: 'bash "/srv/old/../pi-agent/kendex/hooks/guard.sh"', anchor: undefined, expected: "guard" },
]) test(row.name, () => { expect(renderedName(row.root, row.command, row.anchor)).toBe(row.expected); });
