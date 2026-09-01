import type {
  HarnessId,
  ItemKind,
  Manifest_Serialize,
  Scope,
} from "@/bindings";
import { AUTOMATIC_SKILLS, AVAILABLE_SKILLS } from "./fixtures";
import { declaredSkillRows } from "./mock-agent-skills";
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

export const auditHandlers: Record<string, Handler> = {
  audit_all: () => store.state.views,
  apply_plan: ({
    scope,
    removeOrphans,
  }: {
    scope: Scope;
    removeOrphans: boolean;
  }) => {
    const v = view(scope);
    v.drift = v.drift.filter(
      (row) =>
        row.state === "unmanaged" ||
        (row.state === "orphaned" && !removeOrphans),
    );
    v.plan = [];
    return v;
  },
  adopt_item: (args: {
    scope: Scope;
    kind: ItemKind;
    name: string;
    harnesses: HarnessId[];
  }) => {
    const v = view(args.scope);
    v.drift = v.drift.filter(
      (row) =>
        !(
          row.kind === args.kind &&
          row.name === args.name &&
          args.harnesses.includes(row.harness)
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
  // Taking over one item's position: its rows go, and the files that were
  // there are gone from the mock world the same way a real apply moves them
  // to the trash.
  replace_unmanaged_item: (args: {
    scope: Scope;
    kind: ItemKind;
    name: string;
  }) => {
    const v = view(args.scope);
    v.drift = v.drift.filter(
      (row) => !(row.kind === args.kind && row.name === args.name),
    );
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
  get_manifest: ({ scope }: { scope: Scope }) =>
    store.state.manifests[label(scope)] ?? null,
  // The dev shell installs no skills, so no template declares a key here
  // — an answer, the same one a project with nothing settings-shipping
  // gives, rather than a blank the page has to interpret.
  get_scope_settings: ({ scope }: { scope: Scope }) => ({
    applies: scope.scope === "project",
    skills: [],
    base: null,
  }),
  save_customize: ({
    scope,
    manifest: draft,
  }: {
    scope: Scope;
    manifest: { manifest: Manifest_Serialize } | null;
  }) => {
    if (draft) {
      store.state.manifests[label(scope)] = draft.manifest;
    }
    return view(scope);
  },
  editor_inventory: ({ scope }: { scope: Scope }) => {
    const m = store.state.manifests[label(scope)];
    return {
      declaredAgents: Object.keys(m?.agents ?? {}),
      declaredSkills: Object.keys(m?.skills ?? {}),
      availableSkills: AVAILABLE_SKILLS,
      automaticSkills: AUTOMATIC_SKILLS,
      declaredSkillRows: declaredSkillRows(m),
      harnesses: m?.install?.harnesses ?? ["claude"],
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
    const harnesses = m?.install?.harnesses ?? ["claude"];
    return hooks.map(() =>
      harnesses.map((harness) => ({ harness, mode: "runs", note: null })),
    );
  },
};
