// The fixtures run WITH the closing window — the root config's
// `test.setupFiles`, not a copy: delete that line and these runs stop
// differing from the unguarded ones.
import { defineConfig } from "vitest/config";
import base from "../../../vite.config.ts";

export default defineConfig({
  test: {
    include: ["src/test/fixtures/*.fixture.ts"],
    setupFiles: base.test?.setupFiles,
  },
});
