// The context window Pi's own model registry holds for PROVIDER/ID, printed
// as a whole number, and nothing where the registry names none. Run by
// lib/adapters/pi.sh § lane_adapter_pi_registry_window as
// `node pi-registry-window.mjs PI_BIN PROVIDER ID`.
//
// The registry is the SDK's documented `ModelRuntime.create()` and
// `getModel(provider, id)` (the SDK guide of @earendil-works/pi-coding-agent), the
// read that covers the bundled catalog, the cached catalog and the user's
// models.json together. `pi --list-models` rounds the window and lists only
// models with credentials, so it is no source. The SDK is imported from the
// install the `pi` command PI_BIN runs, so the registry read is that Pi's.
import { readFileSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const PACKAGE = "@earendil-works/pi-coding-agent";
const [bin, provider, id] = process.argv.slice(2);

function packageRoot(start) {
  for (let dir = start; ; dir = dirname(dir)) {
    try {
      const manifest = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
      if (manifest.name === PACKAGE) return { dir, manifest };
    } catch {
      // No manifest here, or one that does not parse: keep climbing.
    }
    if (dirname(dir) === dir) return null;
  }
}

const root = packageRoot(dirname(realpathSync(bin)));
const entry = root && (root.manifest.exports?.["."]?.import ?? root.manifest.main);
if (!entry) process.exit(1);
const { ModelRuntime } = await import(pathToFileURL(join(root.dir, entry)).href);
const runtime = await ModelRuntime.create();
const window = runtime.getModel(provider, id)?.contextWindow;
if (Number.isInteger(window) && window > 0) console.log(window);
