import type {
  CustomHook_Deserialize,
  CustomHook_Serialize,
  FrontmatterOverrides_Deserialize,
  FrontmatterOverrides_Serialize,
  HookAgents,
  ItemDecl_Deserialize,
  ItemDecl_Serialize,
  Manifest_Deserialize,
  Manifest_Serialize,
  SourceDecl_Deserialize,
  SourceDecl_Serialize,
} from "@/bindings";
import { MANIFEST_SCHEMA } from "@/bindings";

/** The editor edits the shape `update_manifest` accepts. */
export type Draft = Manifest_Deserialize;
export type DraftHook = CustomHook_Deserialize;
export type DraftFrontmatter = FrontmatterOverrides_Deserialize;

export type InstructionTable =
  | "agent-launch-instructions"
  | "agent-additional-instructions"
  | "skill-instructions";

/** The reserved key that applies an instruction to every agent or skill. */
export const SHARED_KEY = "all";

export const EMPTY_FRONTMATTER: DraftFrontmatter = {
  color: null,
  model: null,
  "deny-tools": null,
  "allow-tools": null,
  "allowed-subagents": null,
  pane: null,
  background: null,
  effort: null,
  isolation: null,
  memory: null,
  mode: null,
  "sandbox-mode": null,
  "model-reasoning-effort": null,
  "nickname-candidates": null,
};

/**
 * The draft the editor opens for a scope with no kendex.toml yet. The
 * schema is the one this build writes, read off the exported constant:
 * `save::check` validates this draft before the plan's `manifest::save`
 * would stamp anything, so a number of our own here would be a first save
 * refused by its own validator.
 */
export function emptyDraft(): Draft {
  return { schema: MANIFEST_SCHEMA };
}

export function emptyHook(): DraftHook {
  return {
    event: "",
    matcher: null,
    command: "",
    description: null,
    agents: SHARED_KEY,
  };
}

function mapValues<A, B>(
  map: Record<string, A>,
  convert: (value: A) => B,
): Record<string, B> {
  return Object.fromEntries(
    Object.entries(map).map(([key, value]) => [key, convert(value)]),
  );
}

function optional<A, B>(
  map: Record<string, A> | undefined,
  convert: (value: A) => B,
): Record<string, B> | undefined {
  return map ? mapValues(map, convert) : undefined;
}

function itemDecl(decl: ItemDecl_Serialize): ItemDecl_Deserialize {
  return { harnesses: null, method: null, ...decl };
}

function sourceDecl(decl: SourceDecl_Serialize): SourceDecl_Deserialize {
  return { repo: null, path: null, rev: null, ...decl };
}

function hook(entry: CustomHook_Serialize): DraftHook {
  return { matcher: null, description: null, ...entry };
}

function frontmatter(
  overrides: FrontmatterOverrides_Serialize,
): DraftFrontmatter {
  return { ...EMPTY_FRONTMATTER, ...overrides };
}

/** A loaded manifest, widened to the shape the editor writes back. */
export function toDraft(manifest: Manifest_Serialize): Draft {
  return {
    ...manifest,
    sources: optional(manifest.sources, sourceDecl),
    agents: optional(manifest.agents, itemDecl),
    skills: optional(manifest.skills, itemDecl),
    hooks: optional(manifest.hooks, itemDecl),
    commands: optional(manifest.commands, itemDecl),
    "mcp-servers": optional(manifest["mcp-servers"], itemDecl),
    "pi-extensions": optional(manifest["pi-extensions"], itemDecl),
    bundles: optional(manifest.bundles, itemDecl),
    "agent-frontmatter": optional(manifest["agent-frontmatter"], (perAgent) =>
      mapValues(perAgent, frontmatter),
    ),
    "custom-hooks": manifest["custom-hooks"]?.map(hook),
  };
}

/**
 * A row exists only once the user customizes an agent; from then on it is
 * authoritative, so an emptied row stays as an explicit "no skills".
 */
export function setAgentSkill(
  draft: Draft,
  agent: string,
  skill: string,
  on: boolean,
): Draft {
  const rows = { ...(draft["agent-skills"] ?? {}) };
  const current = rows[agent];
  if (!current && !on) return draft;
  const skills = new Set(current ?? []);
  if (on) skills.add(skill);
  else skills.delete(skill);
  rows[agent] = [...skills].sort();
  return { ...draft, "agent-skills": rows };
}

/** Hand the agent back to automatic assignment by dropping its row. */
export function clearAgentSkills(draft: Draft, agent: string): Draft {
  const rows = { ...(draft["agent-skills"] ?? {}) };
  delete rows[agent];
  const next = { ...draft };
  if (Object.keys(rows).length === 0) delete next["agent-skills"];
  else next["agent-skills"] = rows;
  return next;
}

export function setInstruction(
  draft: Draft,
  table: InstructionTable,
  key: string,
  text: string | null,
): Draft {
  const entries = { ...(draft[table] ?? {}) };
  if (text === null) delete entries[key];
  else entries[key] = text;
  const next = { ...draft };
  if (Object.keys(entries).length === 0) delete next[table];
  else next[table] = entries;
  return next;
}

function isUnset(overrides: DraftFrontmatter): boolean {
  return Object.values(overrides).every(
    (value) => value === null || (Array.isArray(value) && value.length === 0),
  );
}

export function setFrontmatterField<K extends keyof DraftFrontmatter>(
  draft: Draft,
  harness: string,
  agent: string,
  field: K,
  value: DraftFrontmatter[K],
): Draft {
  const byHarness = { ...(draft["agent-frontmatter"] ?? {}) };
  const perAgent = { ...(byHarness[harness] ?? {}) };
  const overrides = { ...EMPTY_FRONTMATTER, ...perAgent[agent] };
  overrides[field] = value;
  if (isUnset(overrides)) delete perAgent[agent];
  else perAgent[agent] = overrides;
  if (Object.keys(perAgent).length === 0) delete byHarness[harness];
  else byHarness[harness] = perAgent;
  const next = { ...draft };
  if (Object.keys(byHarness).length === 0) delete next["agent-frontmatter"];
  else next["agent-frontmatter"] = byHarness;
  return next;
}

export function addCustomHook(draft: Draft, entry = emptyHook()): Draft {
  return {
    ...draft,
    "custom-hooks": [...(draft["custom-hooks"] ?? []), entry],
  };
}

export function setCustomHook(
  draft: Draft,
  index: number,
  entry: DraftHook,
): Draft {
  const hooks = [...(draft["custom-hooks"] ?? [])];
  if (index < 0 || index >= hooks.length)
    throw new RangeError(`no custom hook at index ${index}`);
  hooks[index] = entry;
  return { ...draft, "custom-hooks": hooks };
}

export function removeCustomHook(draft: Draft, index: number): Draft {
  const hooks = (draft["custom-hooks"] ?? []).filter((_, at) => at !== index);
  const next = { ...draft };
  if (hooks.length === 0) delete next["custom-hooks"];
  else next["custom-hooks"] = hooks;
  return next;
}

export function parseList(text: string): string[] | null {
  const items = text
    .split(",")
    .map((part) => part.trim())
    .filter((part) => part !== "");
  return items.length === 0 ? null : items;
}

export function formatList(list: string[] | null | undefined): string {
  return (list ?? []).join(", ");
}

/** One name stays a bare string — that is how "all" and roles are written. */
export function parseHookAgents(text: string): HookAgents {
  const names = parseList(text);
  if (!names) return SHARED_KEY;
  return names.length === 1 ? names[0] : names;
}

export function formatHookAgents(agents: HookAgents | undefined): string {
  return typeof agents === "string" ? agents : formatList(agents);
}
