---
applyTo: "pi-extensions/*/bundle/**"
---

Files here are committed esbuild artifacts of the extension's `src/`.
Findings in bundle output are legitimate, but frame each finding against the
corresponding `src/` file and never propose patching the bundle itself —
bundles are rebuilt from `src/`, not edited.
