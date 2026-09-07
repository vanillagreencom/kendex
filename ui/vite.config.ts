/// <reference types="vitest/config" />
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import svgr from "vite-plugin-svgr";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react(), svgr(), tailwindcss()],
  resolve: {
    alias: {
      "@": new URL("./src", import.meta.url).pathname,
    },
  },
  clearScreen: false,
  test: {
    // Every test file gets the closing window; the environment stays a
    // per-file choice, on the `// @vitest-environment jsdom` line the files
    // that need a DOM carry.
    setupFiles: ["./src/test/unhandled-rejections.ts"],
    // vitest's 5000 ms default is a wall clock, and the jsdom cases spend
    // theirs on CPU they compete for rather than on a sleep they could be
    // fast-forwarded through: they mount a React tree and drain microtasks,
    // yielding to the real loop only for the tick `user-event` puts between
    // simulated events. Fake timers and a shorter fixture have nothing to
    // bite on there, so the bound is what has to move. On the machine that
    // runs the pre-commit chain — 32 cores under a load average around 110,
    // several cargo and vitest lanes at once — a full run measured 4469 ms
    // for the slowest case, while a different handful crossed 5000 ms on
    // each run and every one of them passed alone. 30000 ms is six times
    // that measured worst case, which absorbs the deeper starvation of an
    // even busier box. Nothing under it bounds a case that truly hangs:
    // `tools/guard` sets no timeout of its own, and CI caps the whole
    // `ui-tests` job at 15 minutes rather than any single case.
    testTimeout: 30_000,
  },
  server: {
    // A port of kendex's own. 5173 is Vite's default, so every other project
    // on the machine is already sitting on it — and Tauri points its window
    // at a fixed URL, so a silent fallback to the next free port shows a
    // blank window instead of the app.
    port: 5273,
    strictPort: true,
  },
});
