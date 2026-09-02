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
