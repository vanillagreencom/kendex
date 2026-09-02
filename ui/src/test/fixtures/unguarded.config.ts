// The fixture run WITHOUT the guard — the must-fail control. Stock vitest
// is green here, which is what makes the guarded run's red mean something.
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/test/fixtures/*.fixture.ts"],
  },
});
