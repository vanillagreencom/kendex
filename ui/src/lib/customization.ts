// What the manifest overlays onto one installed package, read out of the
// manifest the editor already loads. Nothing here is a new fact — it is the
// same tables the Customize page writes, sliced per package so a package's
// own page can show and change its own row.

import type { HarnessId, ItemKind } from "@/bindings";
import {
  clearAgentSkills,
  type Draft,
  type DraftFrontmatter,
  EMPTY_FRONTMATTER,
  SHARED_KEY,
  setInstruction,
} from "@/lib/editor-draft";

/** The kinds a manifest carries an overlay for; the rest install as written. */
const CUSTOMIZABLE = new Set<ItemKind>(["agent", "skill"]);

export const canCustomize = (kind: ItemKind): boolean => CUSTOMIZABLE.has(kind);

/** One package's overlay. Every field is null or empty when nothing is set. */
export interface ItemCustomization {
  /** Agents: text written above and below what the author wrote. */
  launch: string | null;
  additional: string | null;
  /** Skills: text added to the author's own instructions. */
  instructions: string | null;
  /** Agents: the skills this agent gets, or null while kendex picks them. */
  skills: string[] | null;
  /** Agents: per-harness settings, only where any are set. */
  frontmatter: [HarnessId, DraftFrontmatter][];
}

const NOTHING: ItemCustomization = {
  launch: null,
  additional: null,
  instructions: null,
  skills: null,
  frontmatter: [],
};

export function itemCustomization(
  draft: Draft | null,
  kind: ItemKind,
  name: string,
): ItemCustomization {
  if (!draft || !canCustomize(kind)) return NOTHING;
  if (kind === "skill") {
    return {
      ...NOTHING,
      instructions: draft["skill-instructions"]?.[name] ?? null,
    };
  }
  const frontmatter: [HarnessId, DraftFrontmatter][] = [];
  for (const [harness, perAgent] of Object.entries(
    draft["agent-frontmatter"] ?? {},
  )) {
    const overrides = perAgent[name];
    if (overrides) frontmatter.push([harness as HarnessId, overrides]);
  }
  return {
    launch: draft["agent-launch-instructions"]?.[name] ?? null,
    additional: draft["agent-additional-instructions"]?.[name] ?? null,
    instructions: null,
    skills: draft["agent-skills"]?.[name] ?? null,
    frontmatter,
  };
}

/** Whether a person has set anything at all on this package. */
export const isCustomized = (one: ItemCustomization): boolean =>
  one.launch != null ||
  one.additional != null ||
  one.instructions != null ||
  one.skills != null ||
  one.frontmatter.length > 0;

/** What every agent or skill gets on top of its own, from the `all` row. */
export interface SharedCustomization {
  launch: string | null;
  additional: string | null;
  instructions: string | null;
}

export function sharedCustomization(draft: Draft | null): SharedCustomization {
  return {
    launch: draft?.["agent-launch-instructions"]?.[SHARED_KEY] ?? null,
    additional: draft?.["agent-additional-instructions"]?.[SHARED_KEY] ?? null,
    instructions: draft?.["skill-instructions"]?.[SHARED_KEY] ?? null,
  };
}

interface CustomizedItem {
  kind: ItemKind;
  name: string;
  customization: ItemCustomization;
}

/** Every package this manifest customizes, agents first, then by name. The
 *  `all` row is shared, not a package, so it never appears here. */
export function customizedItems(draft: Draft | null): CustomizedItem[] {
  if (!draft) return [];
  const agents = new Set<string>([
    ...Object.keys(draft["agent-launch-instructions"] ?? {}),
    ...Object.keys(draft["agent-additional-instructions"] ?? {}),
    ...Object.keys(draft["agent-skills"] ?? {}),
    ...Object.values(draft["agent-frontmatter"] ?? {}).flatMap((perAgent) =>
      Object.keys(perAgent),
    ),
  ]);
  const skills = new Set<string>(
    Object.keys(draft["skill-instructions"] ?? {}),
  );
  const named = (kind: ItemKind, names: Set<string>): CustomizedItem[] =>
    [...names]
      .filter((name) => name !== SHARED_KEY)
      .sort()
      .map((name) => ({
        kind,
        name,
        customization: itemCustomization(draft, kind, name),
      }));
  return [...named("agent", agents), ...named("skill", skills)];
}

/** The settings a harness has for one agent, ready to render — an unset one
 *  reads as every field blank rather than as a missing row. */
export function frontmatterFor(
  one: ItemCustomization,
  harness: HarnessId,
): DraftFrontmatter {
  const found = one.frontmatter.find(([id]) => id === harness);
  return found ? found[1] : EMPTY_FRONTMATTER;
}

/** Drop everything set on one package, leaving it as its author wrote it. */
export function clearItemCustomization(
  draft: Draft,
  kind: ItemKind,
  name: string,
): Draft {
  let next = draft;
  if (kind === "skill") {
    return setInstruction(next, "skill-instructions", name, null);
  }
  next = setInstruction(next, "agent-launch-instructions", name, null);
  next = setInstruction(next, "agent-additional-instructions", name, null);
  next = clearAgentSkills(next, name);
  const byHarness: Record<string, Record<string, DraftFrontmatter>> = {};
  for (const [harness, perAgent] of Object.entries(
    next["agent-frontmatter"] ?? {},
  )) {
    const rest = { ...perAgent };
    delete rest[name];
    if (Object.keys(rest).length > 0) byHarness[harness] = rest;
  }
  next = { ...next };
  if (Object.keys(byHarness).length === 0) delete next["agent-frontmatter"];
  else next["agent-frontmatter"] = byHarness;
  return next;
}
