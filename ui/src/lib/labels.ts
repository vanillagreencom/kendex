// The product vocabulary, in one place: internal ids stay technical,
// everything a person reads goes through these maps.
import type { HarnessId, ItemKind, Scope, Severity, Tag } from "@/bindings";
import type { Page } from "@/stores/nav";

export const HARNESS_NAMES: Record<HarnessId, string> = {
  claude: "Claude Code",
  codex: "Codex",
  opencode: "OpenCode",
  cursor: "Cursor",
  pi: "Pi",
  gemini: "Gemini CLI",
  copilot: "GitHub Copilot",
};

export const harnessName = (id: HarnessId): string => HARNESS_NAMES[id];

const KIND_LABELS: Record<ItemKind, { one: string; many: string }> = {
  agent: { one: "Agent", many: "Agents" },
  skill: { one: "Skill", many: "Skills" },
  hook: { one: "Hook", many: "Hooks" },
  command: { one: "Command", many: "Commands" },
  "mcp-server": { one: "MCP server", many: "MCP servers" },
  plugin: { one: "Plugin", many: "Plugins" },
  "pi-extension": { one: "Pi extension", many: "Pi extensions" },
};

export const kindLabel = (kind: ItemKind, count = 1): string =>
  count === 1 ? KIND_LABELS[kind].one : KIND_LABELS[kind].many;

// A hook and an MCP server have nowhere to write a description — no
// frontmatter, just an entry in a config file — so what stands in for one is
// the command they run. That is the only thing telling two of them apart, so
// it stays on screen, but it is a literal and reads as one: set in mono, not
// in the same voice as an author's sentence.
const RUNS_A_COMMAND: ReadonlySet<ItemKind> = new Set<ItemKind>([
  "hook",
  "mcp-server",
]);

export const describesItself = (kind: ItemKind): boolean =>
  !RUNS_A_COMMAND.has(kind);

// What each tag is called on screen. The written form is lower-case (it is
// what an author types into a file); the label is what a reader sees.
export const TAG_LABELS: Record<Tag, string> = {
  review: "Review",
  testing: "Testing",
  docs: "Docs",
  research: "Research",
  planning: "Planning",
  refactoring: "Refactoring",
  debugging: "Debugging",
  security: "Security",
  performance: "Performance",
  git: "Git",
  release: "Release",
  data: "Data",
  ui: "UI",
  integration: "Integration",
  automation: "Automation",
};

// How serious a safety finding is, said without security jargon.
export const SEVERITY_LABELS: Record<Severity, string> = {
  critical: "Serious",
  high: "Important",
  medium: "Worth a look",
  low: "Minor",
};

// A collapsed row's dot: high and critical share the most urgent tone since
// both mean "worth stopping for"; low fades toward an already-checked item.
export const SEVERITY_DOT_TONE: Record<
  Severity,
  "critical" | "warning" | "muted"
> = {
  critical: "critical",
  high: "critical",
  medium: "warning",
  low: "muted",
};

// "Personal" (Claude Code convention) lives in the home folder and applies everywhere; project items travel with the repo.
export function scopeName(scope: Scope): string {
  if (scope.scope === "global") return "Personal";
  return scope.root.split("/").pop() ?? scope.root;
}

export function scopePath(scope: Scope): string | null {
  return scope.scope === "global" ? null : scope.root;
}

/** Names for a set of places, each one telling its holder apart from the
 * others in the set. `scopeName` is a folder's basename, so ~/dev/kendex
 * and ~/work/kendex read identically — two lines of a note naming the same
 * thing, with nothing to say which had the problem. Where a name is shared,
 * the entries holding it carry their full path instead. Returned in the
 * order given, one per scope. */
export function scopeNames(scopes: Scope[]): string[] {
  const holders = new Map<string, Set<string>>();
  for (const scope of scopes) {
    const name = scopeName(scope);
    const holder = holders.get(name) ?? new Set<string>();
    holder.add(scopePath(scope) ?? "");
    holders.set(name, holder);
  }
  return scopes.map((scope) => {
    const name = scopeName(scope);
    const path = scopePath(scope);
    return path !== null && (holders.get(name)?.size ?? 1) > 1 ? path : name;
  });
}

// A hook's raw identifier is "<event>:<matcher>:<name>" or "<event>:<name>" — a person reads the trailing name; the full id stays in a mono line.
export function hookDisplayName(id: string): string {
  const parts = id.split(":");
  return parts[parts.length - 1] || id;
}

/** The engine writes its findings as sentence fragments; anywhere one
 *  stands on its own, it starts a sentence. */
export function sentence(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

const PAGE_LABELS: Record<Page, string> = {
  home: "Home",
  library: "My Library",
  marketplaces: "Marketplaces",
  updates: "Updates",
  harnesses: "Harnesses",
  projects: "Projects",
  unmanaged: "Not managed",
  customize: "Customize",
  settings: "Settings",
  problems: "Problems",
  package: "Package",
  marketplaceDetail: "Marketplace",
  bundleDetail: "Bundle",
  availablePackage: "Package",
};

// Where you are, in one line — only nested pages spell out a trail; a base
// page reads as just its name.
export function breadcrumbLabel(nav: {
  page: Page;
  /** The open package's display name, when the page is a package. */
  packageName?: string | null;
  /** The open subscription's name, on the marketplace-nested pages. */
  marketplaceName?: string | null;
  /** The open bundle's name, on the bundle page. */
  bundleName?: string | null;
}): string {
  if (nav.page === "package" && nav.packageName) {
    return `${PAGE_LABELS.library} / ${nav.packageName}`;
  }
  if (nav.page === "marketplaceDetail" && nav.marketplaceName) {
    return `${PAGE_LABELS.marketplaces} / ${nav.marketplaceName}`;
  }
  if (nav.page === "bundleDetail" && nav.marketplaceName && nav.bundleName) {
    return `${PAGE_LABELS.marketplaces} / ${nav.marketplaceName} / ${nav.bundleName}`;
  }
  if (nav.page === "availablePackage" && nav.marketplaceName) {
    return `${PAGE_LABELS.marketplaces} / ${nav.marketplaceName} / ${nav.packageName ?? ""}`;
  }
  return PAGE_LABELS[nav.page];
}

/** A subscription's declared revision, on screen. A full commit id is
 * shortened the way every git surface shortens one; anything else is a tag
 * or a branch, which `source_ref::check_rev` allows to contain slashes and
 * dots, and cutting it to seven characters would spell a different ref —
 * `release/2026` as "release", `v2.1.0-beta` as "v2.1.0", a tag that may
 * itself exist. A name is shown whole or not at all.
 *
 * A commit id is the same question core's `remote::store::is_pin` asks —
 * forty ASCII hex digits — so the class matches its case-insensitivity: a
 * manifest may pin an uppercase id, and `rev` keeps the spelling declared. */
export function shortRevision(revision: string): string {
  return /^[0-9a-f]{40}$/i.test(revision) ? revision.slice(0, 7) : revision;
}

/** How a package's name reads to a person — hooks carry display names. */
export function packageDisplayName(ref: {
  kind: ItemKind;
  name: string;
}): string {
  return ref.kind === "hook" ? hookDisplayName(ref.name) : ref.name;
}

// Settings page copy, kept here so the wording is reviewed in one place.
export const SETTINGS_SUBTITLE = "How kendex looks and behaves on this machine";
