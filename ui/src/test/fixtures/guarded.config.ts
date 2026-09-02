// The fixtures run WITH the closing window. Paired with
// `unguarded.config.ts`, the same run without it;
// `../unhandled-rejections.test.ts` runs each fixture under both.
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/test/fixtures/*.fixture.ts"],
    setupFiles: ["./src/test/unhandled-rejections.ts"],
  },
});
