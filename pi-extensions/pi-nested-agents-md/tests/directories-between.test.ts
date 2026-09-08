import { expect, test } from "bun:test";
import { directoriesBetween } from "../extensions/nested-agents-md.ts";

for (const row of [
	{ name: "root-most first with root excluded", file: "/r/a/b/x.ts", expected: ["/r/a", "/r/a/b"] },
	{ name: "root file excludes the root", file: "/r/x.ts", expected: [] },
]) {
	test(row.name, () => {
		expect(directoriesBetween(row.file, "/r")).toEqual(row.expected);
	});
}

test("refuses an outside file before walking beyond the filesystem root", () => {
	let failure: unknown;
	try { directoriesBetween("/elsewhere/x.ts", "/r"); } catch (error) { failure = error; }
	expect(failure).toMatchObject({ code: "OUTSIDE_ROOT", path: "/elsewhere/x.ts", root: "/r" });
	expect((failure as Error).message.split("\n")[0]).toBe("outside_root=/elsewhere/x.ts");
});
