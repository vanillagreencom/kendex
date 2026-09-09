// The same fixtures without the closing window: the baseline the guarded
// runs are read against.
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/test/fixtures/*.fixture.ts"],
  },
});
