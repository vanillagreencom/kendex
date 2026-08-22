import type {
  HarnessId,
  ItemKind,
  Manifest_Serialize,
  Scope,
} from "@/bindings";
import { AVAILABLE_SKILLS } from "./fixtures";
import {
  DECL_KEYS,
  declTable,
  type Handler,
  label,
  manifest,
  same,
  store,
  view,
} from "./mock-state";

// The same list core sends, so the picker can be driven in the browser.
const HOOK_EVENTS = [
  { name: "SessionStart", fires: "A session starts" },
  { name: "SessionEnd", fires: "A session ends" },
  { name: "UserPromptSubmit", fires: "You send a prompt" },
  { name: "PreToolUse", fires: "Before the agent runs a tool" },
  { name: "PostToolUse", fires: "After a tool returns" },
  {
    name: "PermissionRequest",
    fires: "The agent asks permission for something",
  },
  { name: "Notification", fires: "The agent sends a notification" },
  { name: "Stop", fires: "The agent finishes its turn" },
  { name: "SubagentStop", fires: "A subagent finishes" },
  { name: "PreCompact", fires: "Before the conversation is compacted" },
  { name: "PostCompact", fires: "After the conversation is compacted" },
  { name: "TaskCompleted", fires: "Before a task is marked complete" },
];

/** What the place's manifest is right now, as a copy read from it would
 *  remember: the mock's stand-in for hashing the file. */
const base = (scope: Scope): string | null => {
  const held = store.state.manifests[label(scope)];
  return held ? JSON.stringify(held) : null;
};

export const auditHandlers: Record<string, Handler> = {
  audit_all: () => store.state.views,
  apply_plan: ({
    scope,
    removeOrphans,
    allowUnsafe,
  }: {
    scope: Scope;
    removeOrphans: boolean;
    allowUnsafe: string[];
  }) => {
    const v = view(scope);
    v.drift = v.drift.filter(
      (row) =>
        row.state === "unmanaged" ||
        (row.state === "orphaned" && !removeOrphans),
    );
    v.plan = [];
    const accepted = new Set(allowUnsafe.map((token) => token.split("@")[0]));
    if (accepted.size > 0) {
      v.heldBack = v.heldBack.filter((row) => !accepted.has(row.name));
      for (const row of v.safety) {
        if (accepted.has(row.name)) row.override = { state: "active" };
      }
    }
    return v;
  },
  adopt_item: (args: {
    scope: Scope;
    kind: ItemKind;
    name: string;
    harness: HarnessId;
  }) => {
    const v = view(args.scope);
    v.drift = v.drift.filter(
      (row) =>
        !(
          row.kind === args.kind &&
          row.name === args.name &&
          row.harness === args.harness
        ),
    );
    const table = declTable(manifest(args.scope), args.kind);
    if (table) table[args.name] = { source: "local", enabled: true };
    for (const it of store.state.items) {
      if (
        it.kind === args.kind &&
        it.name === args.name &&
        same(it.scope, args.scope)
      ) {
        it.origin = "local";
      }
    }
    return v;
  },
  toggle_item: ({
    scope,
    name,
    enabled,
  }: {
    scope: Scope;
    name: string;
    enabled: boolean;
  }) => {
    for (const it of store.state.items) {
      if (it.name === name && same(it.scope, scope)) it.enabled = enabled;
    }
    const m = manifest(scope);
    for (const key of Object.values(DECL_KEYS)) {
      const entry = m[key]?.[name];
      if (entry) entry.enabled = enabled;
    }
    return view(scope);
  },
  remove_item: ({ scope, name }: { scope: Scope; name: string }) => {
    store.state.items = store.state.items.filter(
      (it) => !(it.name === name && same(it.scope, scope)),
    );
    const m = manifest(scope);
    for (const key of Object.values(DECL_KEYS)) {
      const table = m[key];
      if (table?.[name]) {
        m[key] = Object.fromEntries(
          Object.entries(table).filter(([k]) => k !== name),
        );
      }
    }
    for (const row of store.state.sources) {
      if (same(row.scope, scope)) {
        row.declaredItems = row.declaredItems.filter((n) => n !== name);
      }
    }
    return view(scope);
  },
  get_manifest: ({ scope }: { scope: Scope }) => ({
    manifest: store.state.manifests[label(scope)] ?? null,
    base: base(scope),
  }),
  // The real write refuses a copy read from a file that has since become
  // something else. The mock has no file, so the stand-in for "what the
  // file is" is what the store holds — enough for the dev shell to show
  // the refusal a stale save gets.
  update_manifest: ({
    scope,
    manifest: m,
    base: held,
  }: {
    scope: Scope;
    manifest: Manifest_Serialize;
    base: string | null;
  }) => {
    if (held !== base(scope)) throw { kind: "stale" };
    store.state.manifests[label(scope)] = m;
    return { view: view(scope), base: base(scope) };
  },
  editor_inventory: ({ scope }: { scope: Scope }) => {
    const m = store.state.manifests[label(scope)];
    return {
      declaredAgents: Object.keys(m?.agents ?? {}),
      declaredSkills: Object.keys(m?.skills ?? {}),
      availableSkills: AVAILABLE_SKILLS,
      harnesses: m?.install.harnesses ?? ["claude"],
      hookEvents: HOOK_EVENTS,
    };
  },
  // The dev shell has no engine to ask, so every drafted hook reads as
  // running everywhere the mock scope installs to.
  custom_hook_deliveries: ({
    scope,
    hooks,
  }: {
    scope: Scope;
    hooks: unknown[];
  }) => {
    const m = store.state.manifests[label(scope)];
    const harnesses = m?.install.harnesses ?? ["claude"];
    return hooks.map(() =>
      harnesses.map((harness) => ({ harness, mode: "runs", note: null })),
    );
  },
};
