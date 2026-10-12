import { expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { tempRuntime } from "./single-agent-fixture.js";

const dirs: string[] = [];
test("runtime fixture without caller teardown: passing test", () => { dirs.push(tempRuntime(), tempRuntime()); });
test.failing("runtime fixture without caller teardown: failing test", () => {
	dirs.push(tempRuntime(), tempRuntime());
	throw new Error("fixture owner must clean up after this failure");
});
test("all runtime directories are gone after their tests end", () => { expect(dirs.filter(existsSync)).toEqual([]); });
