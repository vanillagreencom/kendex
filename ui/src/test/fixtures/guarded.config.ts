// The fixture run WITH the guard. Paired with `unguarded.config.ts`, which
// is the same run without it; `../unhandled-rejections.test.ts` runs both.
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/test/fixtures/*.fixture.ts"],
    setupFiles: ["./src/test/unhandled-rejections.ts"],
  },
});
