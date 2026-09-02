// The fixtures run WITHOUT the closing window: the measured baseline every
// guarded verdict is read against. Stock vitest is green on the
// late-rejection fixture and red on the skipped-file one, and the setup file
// has to change the first without costing the second.
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/test/fixtures/*.fixture.ts"],
  },
});
