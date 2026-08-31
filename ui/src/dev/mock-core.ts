import type {
  AppSettings,
  HarnessId,
  ItemKind,
  ProvenanceRow,
  Scope,
} from "@/bindings";
import { capabilityTable } from "./caps";
import { type Handler, label, same, store, view } from "./mock-state";

const RUNNING_VERSION = "0.1.0";
const RELEASED_VERSION = "0.2.0";

/** The query string drives the update notice, so browser automation walks
 *  every state of the card without a rebuild:
 *
 *  - `?update=direct` — the card with Update now (the default when the
 *    parameter names nothing else).
 *  - `?update=managed` — the card with a package manager's command.
 *  - `?update=unknown` — the card with no action at all.
 *  - `?update=none` — no card: this build is the latest.
 *  - `?update=commandManaged` — Update now, and the `kendex` command
 *    beside the app named as another installer's to move.
 *  - `?update=commandPrivilege` — Update now, and the `kendex` command
 *    beside the app named as one this app cannot write.
 *  - `?update=commandDownload` — the same, on a platform with no
 *    installer to re-run.
 *  - `?updateFails=1` — the replacement refuses, and says so on the card. */
const wanted = (name: string): string | null =>
  typeof window === "undefined"
    ? null
    : new URLSearchParams(window.location.search).get(name);

/** Every settings-returning command answers with the file and what it was
 *  when it was read. The mock has one writer, so the copy it hands out is
 *  always current and carries no base to check it against. */
const settingsRead = () => ({ settings: store.state.settings, base: null });

export const coreHandlers: Record<string, Handler> = {
  app_version: () => RUNNING_VERSION,
  app_update_check: () =>
    wanted("update") === "none" || wanted("update") === null
      ? { kind: "upToDate", version: RUNNING_VERSION }
      : {
          kind: "updateAvailable",
          version: RELEASED_VERSION,
          releaseNotesUrl: `https://github.com/vanillagreencom/kendex/releases/tag/v${RELEASED_VERSION}`,
          cliAssetAvailable: true,
          // What a dismissal wrote, read back the way the engine reads
          // it: one version, so the next release notifies again.
          muted: store.state.settings["muted-app-notice"] === RELEASED_VERSION,
        },
  app_update_channel: () => {
    switch (wanted("update")) {
      case "managed":
        return {
          kind: "managed",
          manager: "an AUR helper",
          command: "paru -S kendex-bin",
        };
      case "unknown":
        return { kind: "unknown" };
      default:
        return { kind: "direct" };
    }
  },
  // What the card owes a person about the `kendex` command beside the app.
  // Null is the ordinary machine: no command here, or one Update now
  // carries across itself.
  app_update_command_channel: () => {
    switch (wanted("update")) {
      case "commandManaged":
        return {
          kind: "managed",
          manager: "Homebrew",
          command: "brew upgrade kendex-cli",
        };
      case "commandPrivilege":
        return {
          kind: "needsPrivilege",
          path: "/usr/local/bin/kendex",
          command: "curl -fsSL https://kendex.ai/install.sh | sh",
        };
      case "commandDownload":
        return {
          kind: "needsDownload",
          path: "C:\\Program Files\\kendex\\kendex.exe",
          page: "https://kendex.ai/download",
        };
      default:
        return null;
    }
  },
  // The mock browser harness has no install to replace, so the successful
  // path is the one thing it cannot show: the real command relaunches the
  // app and never returns. A refusal is a plain string, which is what the
  // bridge rejects with.
  app_update_install: () => {
    if (wanted("updateFails") !== null)
      throw "the release could not be verified against the updater key";
    return null;
  },
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
  // Read off the page, the way the real reader reads it off the webview:
  // the mock takes every size, so it is never at one it refused.
  window_zoom_state: () => ({
    percent: Math.round(Number(document.documentElement.style.zoom || 1) * 100),
    launchRefused: false,
  }),
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
  get_settings: () => settingsRead(),
  update_settings: ({ settings }: { settings: AppSettings }) => {
    // The size is the window's; a settings save carries a copy that may
    // predate the last resize, so the stored one stands.
    store.state.settings = { ...settings, zoom: store.state.settings.zoom };
    return settingsRead();
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
    return settingsRead();
  },
  install_drift_hook: () => null,
  // A freshly registered project in the dev app has nothing waiting: the
  // fixture scopes are already declared.
  project_offers: () => [],
  unregister_project: ({ path }: { path: string }) => {
    store.state.settings.projects = (
      store.state.settings.projects ?? []
    ).filter((p) => p !== path);
    store.state.views = store.state.views.filter(
      (v) => label(v.scope) !== path,
    );
    return settingsRead();
  },
  discover_projects: ({ root }: { root: string }) =>
    ["acme-web", "api-server", "demo-app"].map(
      (name) => `${root.replace(/\/+$/, "")}/${name}`,
    ),
  report_route: ({
    scope,
    name,
    kind,
  }: {
    scope: Scope;
    name: string;
    kind: ItemKind | null;
  }) => {
    const upstream = "vanillagreencom/kendex";
    // Mirrors the engine's rule: the recorded origin decides, for every kind
    // alike, and one row from anywhere else makes the name ambiguous. The
    // provenance table is the mock's lock — an observed item's origin is the
    // git origin of wherever its file sits, which for a skill installed by
    // link is the consuming repository.
    const matching = store.state.provenance.filter(
      (row) =>
        row.name === name &&
        same(row.scope, scope) &&
        (kind === null || row.kind === kind),
    );
    const recorded = (row: ProvenanceRow) =>
      row.origin.origin === "marketplace" ? row.origin.repo : null;
    const owned =
      matching.length > 0 &&
      matching.every((row) => recorded(row) === upstream);
    const agreed = matching.every((row) => row.kind === matching[0]?.kind)
      ? matching[0]?.kind
      : undefined;
    const resolved = kind ?? agreed;
    // Mirrors derive_label.
    const label = !owned
      ? null
      : name.includes("review-gate")
        ? "ci-infra"
        : resolved === "hook" || resolved === "pi-extension"
          ? "harness"
          : resolved === "skill" || resolved === "agent"
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
