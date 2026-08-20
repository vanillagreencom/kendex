import type { AppSettings, HarnessId, ItemKind, Scope } from "@/bindings";
import { capabilityTable } from "./caps";
import { type Handler, label, same, store, view } from "./mock-state";

export const coreHandlers: Record<string, Handler> = {
  app_version: () => "0.1.0",
  capability_table: () => capabilityTable(),
  // No real window or OS pickers to act on in the mock browser harness.
  window_minimize: () => null,
  window_toggle_maximize: () => null,
  window_close: () => null,
  // The one window command with a browser equivalent: CSS zoom scales the
  // page the same way the webview's own zoom does.
  window_set_zoom: ({ percent }: { percent: number }) => {
    document.documentElement.style.zoom = String(percent / 100);
    return null;
  },
  pick_folder: () => null,
  reveal_path: () => null,
  open_in_editor: () => null,
  item_source: ({
    kind,
    name,
  }: {
    scope: Scope;
    kind: ItemKind;
    name: string;
    harness: HarnessId;
  }) =>
    // Hooks preview as a shell script so the mono code path is exercised
    // in the mock, not only the markdown one.
    kind === "hook"
      ? {
          path: `~/.claude/hooks/${name}.sh`,
          content: `#!/usr/bin/env bash\n# ${name} — mock hook body\nset -euo pipefail\necho "hook ${name} ran"\n`,
          truncated: false,
        }
      : {
          path: `~/.claude/${kind}s/${name}${kind === "skill" ? "/SKILL.md" : ".md"}`,
          content: `---\nname: ${name}\ndescription: A mock ${kind} for preview.\n---\n\nThis is placeholder content for **${name}**.\n`,
          truncated: false,
        },
  scan_machine: () => ({
    harnesses: store.state.harnesses,
    items: store.state.items,
    missingProjects: store.state.missingProjects,
    warnings: store.state.warnings,
  }),
  get_settings: () => store.state.settings,
  update_settings: ({ settings }: { settings: AppSettings }) => {
    // The size is the window's; a settings save carries a copy that may
    // predate the last resize, so the stored one stands.
    store.state.settings = { ...settings, zoom: store.state.settings.zoom };
    return store.state.settings;
  },
  save_zoom: ({ percent }: { percent: number }) => {
    store.state.settings.zoom = percent;
    return percent;
  },
  register_project: ({ path }: { path: string }) => {
    const projects = store.state.settings.projects ?? [];
    if (!projects.includes(path)) {
      store.state.settings.projects = [...projects, path];
    }
    view({ scope: "project", root: path });
    return store.state.settings;
  },
  install_drift_hook: () => null,
  unregister_project: ({ path }: { path: string }) => {
    store.state.settings.projects = (
      store.state.settings.projects ?? []
    ).filter((p) => p !== path);
    store.state.views = store.state.views.filter(
      (v) => label(v.scope) !== path,
    );
    return store.state.settings;
  },
  discover_projects: ({ root }: { root: string }) =>
    ["acme-web", "api-server", "demo-app"].map(
      (name) => `${root.replace(/\/+$/, "")}/${name}`,
    ),
  report_route: ({ scope, name }: { scope: Scope; name: string }) => {
    const upstream = "vanillagreencom/kendex";
    // Mirrors the engine's rule: skills never route upstream through
    // provenance alone, everything else from the catalog does.
    const owned = store.state.items.some(
      (it) =>
        it.name === name &&
        same(it.scope, scope) &&
        it.kind !== "skill" &&
        it.origin === upstream,
    );
    const kind = store.state.items.find((it) => it.name === name)?.kind;
    const label = !owned
      ? null
      : kind === "hook" || kind === "pi-extension"
        ? "harness"
        : kind === "agent"
          ? "skills"
          : "cli";
    return {
      kendexOwned: owned,
      repo: owned ? upstream : null,
      label,
      issueUrl: owned
        ? `https://github.com/${upstream}/issues/new?title=${encodeURIComponent(`${name}: `)}${label ? `&labels=${label}` : ""}`
        : null,
    };
  },
};
