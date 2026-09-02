import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import svgr from "vite-plugin-svgr";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [react(), svgr(), tailwindcss()],
  resolve: {
    alias: {
      "@": new URL("./src", import.meta.url).pathname,
    },
  },
  test: {
    // Store hygiene for the whole suite, not per file — see the file's
    // own comment for why a per-file reset does not hold.
    setupFiles: ["./vitest.setup.ts"],
  },
  clearScreen: false,
  server: {
    // A port of kendex's own. 5173 is Vite's default, so every other project
    // on the machine is already sitting on it — and Tauri points its window
    // at a fixed URL, so a silent fallback to the next free port shows a
    // blank window instead of the app.
    port: 5273,
    strictPort: true,
  },
});
