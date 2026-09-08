import { integrityWorld } from "./lib/integrity-fixture.mjs";
import { test } from "node:test";
import assert from "node:assert/strict";
import { appendIntegrityEntry, INTEGRITY_CUSTOM_TYPE } from "../src/index.js";
import { setExtensionApi } from "../src/bridge-state.js";

test("integrity entry reports whether the session accepted it", async (t) => {
	for (const destination of ["session", "missing", "throws"]) {
		await t.test(destination, (t) => {
			const world = integrityWorld(t);
			if (destination === "missing") setExtensionApi(undefined);
			if (destination === "throws") setExtensionApi({ appendEntry() { throw new Error("append failed"); } });
			const appended = appendIntegrityEntry("anything", { count: 1 });
			assert.deepEqual({ appended, entries: world.sessionEntries.map(({ customType, data }) => ({ customType, label: data.label, count: data.count })) },
				{ appended: destination === "session", entries: destination === "session" ? [{ customType: INTEGRITY_CUSTOM_TYPE, label: "anything", count: 1 }] : [] });
		});
	}
});
