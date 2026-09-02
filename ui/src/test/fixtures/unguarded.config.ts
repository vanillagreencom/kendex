// The same fixtures without the closing window: the baseline each guarded
// verdict is read against, measured rather than assumed.
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/test/fixtures/*.fixture.ts"],
  },
});
