import type {
  AuditView,
  ItemKind,
  Manifest_Serialize,
  Scope,
} from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { initialState } from "./fixtures";

export type Handler = (args: never) => unknown;

export const store = { state: initialState() };

export function resetState(): void {
  store.state = initialState();
}

export const label = (scope: Scope): string =>
  scope.scope === "global" ? "global" : scope.root;

export const same = (a: Scope, b: Scope): boolean => label(a) === label(b);

export function view(scope: Scope): AuditView {
  const found = store.state.views.find((v) => same(v.scope, scope));
  if (found) return found;
  const fresh: AuditView = {
    scope,
    drift: [],
    plan: [],
    notes: [],
    warnings: [],
    safety: [],
    adoptable: ADOPTABLE,
    heldBack: [],
    queued: [],
  };
  store.state.views.push(fresh);
  return fresh;
}

export function manifest(scope: Scope): Manifest_Serialize {
  store.state.manifests[label(scope)] ??= { schema: 1, install: {} };
  return store.state.manifests[label(scope)];
}

export const DECL_KEYS = {
  agent: "agents",
  skill: "skills",
  hook: "hooks",
  command: "commands",
  "mcp-server": "mcp-servers",
  "pi-extension": "pi-extensions",
} as const;

export function declTable(m: Manifest_Serialize, kind: ItemKind) {
  if (!(kind in DECL_KEYS)) return null;
  const key = DECL_KEYS[kind as keyof typeof DECL_KEYS];
  m[key] ??= {};
  return m[key];
}

export function sourceRow(scope: Scope, name: string) {
  return store.state.sources.find(
    (row) => row.name === name && same(row.scope, scope),
  );
}
