// The same fixtures without the closing window: the baseline the guarded
// runs are read against, for the three fixtures that have one. fake-timers
// is guarded-only — there is nothing here for it to hang on.
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/test/fixtures/*.fixture.ts"],
  },
});
