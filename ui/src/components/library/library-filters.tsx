import { Search, X } from "lucide-react";
import { useEffect, useRef } from "react";
import type { HarnessId, ItemKind, Tag } from "@/bindings";
import { ScopePills } from "@/components/library/scope-pills";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { TAGS_ROW_LABEL } from "@/lib/copy";
import type { ScopeSelection } from "@/lib/derive";
import { harnessName, kindLabel, TAG_LABELS } from "@/lib/labels";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useNavStore } from "@/stores/nav";

const KINDS: ItemKind[] = [
  "agent",
  "skill",
  "hook",
  "command",
  "mcp-server",
  "plugin",
  "pi-extension",
];
// Derived, not written out again: a tag missing from the filter is a tag
// nobody can find, and nothing would have caught a hand-kept list drifting.
const TAGS = Object.keys(TAG_LABELS) as Tag[];
const HARNESSES: HarnessId[] = [
  "claude",
  "codex",
  "opencode",
  "cursor",
  "pi",
  "gemini",
  "copilot",
];

export function LibraryFilters({
  search,
  onSearchChange,
  kind,
  onKindChange,
  harness,
  onHarnessChange,
  tag,
  onTagChange,
  from,
  onFromChange,
  fromOptions,
  scope,
  onScopeChange,
  projects,
  shown,
  total,
  counting,
  filtered,
  onClear,
}: {
  search: string;
  onSearchChange: (value: string) => void;
  kind: string;
  onKindChange: (value: string) => void;
  harness: string;
  onHarnessChange: (value: string) => void;
  tag: string;
  onTagChange: (value: string) => void;
  from: string;
  onFromChange: (value: string) => void;
  /** The origins the provenance join actually carries, already labelled. */
  fromOptions: string[];
  scope: ScopeSelection;
  onScopeChange: (scope: ScopeSelection) => void;
  projects: string[];
  /** Rows the table is showing, against every row it could show. */
  shown: number;
  total: number;
  /** The first scan hasn't landed, so there is no count to state yet. */
  counting: boolean;
  filtered: boolean;
  onClear: () => void;
}) {
  const searchFocus = useNavStore((s) => s.searchFocus);
  const searchRef = useRef<HTMLInputElement>(null);

  // The "/" shortcut fires from any page, so it bumps a counter rather than
  // reaching for a box that may not have been mounted at the time.
  useEffect(() => {
    if (searchFocus === 0) return;
    searchRef.current?.focus();
    searchRef.current?.select();
  }, [searchFocus]);

  return (
    <div className={cn("border-b pt-1 pb-5", PAGE_GUTTER)}>
      <div className={cn("flex flex-col gap-5", WIDE_CONTENT_WIDTH)}>
        {/* Finding a thing by name is the common errand, so search leads and
            the pickers refine what it returns. They wrap rather than scroll
            sideways: a filter you cannot see is a filter you forget is on. */}
        <div className="flex flex-wrap items-center gap-2">
          <div className="relative min-w-56 flex-1 md:max-w-96">
            <Search className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              ref={searchRef}
              value={search}
              onChange={(event) => onSearchChange(event.target.value)}
              placeholder="Search by name or description"
              aria-label="Search installed items"
              className="pr-9 pl-9"
            />
            {search ? (
              <button
                type="button"
                aria-label="Clear search"
                onClick={() => onSearchChange("")}
                className="absolute top-1/2 right-2 -translate-y-1/2 rounded p-1 text-muted-foreground hover:text-foreground"
              >
                <X className="size-3.5" />
              </button>
            ) : (
              <kbd className="pointer-events-none absolute top-1/2 right-3 -translate-y-1/2 rounded bg-foreground/[0.07] px-1.5 py-0.5 font-mono text-[11px] leading-none text-muted-foreground">
                /
              </kbd>
            )}
          </div>
          <FacetSelect
            label="Type"
            empty="All types"
            value={kind}
            onChange={onKindChange}
            options={KINDS.map((k) => [k, kindLabel(k, 2)])}
          />
          <FacetSelect
            label={TAGS_ROW_LABEL}
            empty="All uses"
            value={tag}
            onChange={onTagChange}
            options={TAGS.map((t) => [t, TAG_LABELS[t]])}
          />
          <FacetSelect
            label="Harness"
            empty="All harnesses"
            value={harness}
            onChange={onHarnessChange}
            options={HARNESSES.map((h) => [h, harnessName(h)])}
          />
          <FacetSelect
            label="From"
            empty="Any origin"
            value={from}
            onChange={onFromChange}
            options={fromOptions.map((label) => [label, label])}
          />
        </div>
        <div className="flex flex-wrap items-center justify-between gap-x-6 gap-y-3">
          {projects.length > 0 || scope !== "all" ? (
            // With no projects and nowhere picked there is nothing to choose
            // between — the pills would offer two buttons showing the same
            // list. Once somewhere is picked they always show, so where the
            // table is looking is never a narrowing with no cause on screen.
            <ScopePills
              scope={scope}
              onScopeChange={onScopeChange}
              projects={projects}
            />
          ) : (
            <span />
          )}
          <div className="flex items-center gap-3 text-xs text-muted-foreground">
            {counting ? (
              <Skeleton className="h-3 w-16" />
            ) : (
              <span className="tabular-nums">
                {shown === total ? `${total} items` : `${shown} of ${total}`}
              </span>
            )}
            {filtered ? (
              <button
                type="button"
                onClick={onClear}
                className="underline underline-offset-2 hover:text-foreground"
              >
                Clear filters
              </button>
            ) : null}
          </div>
        </div>
      </div>
    </div>
  );
}

/** One picker. Narrowed pickers name their facet ("Type: Agents") so a row
 *  of chosen values never reads as an unlabelled list of nouns. */
function FacetSelect({
  label,
  empty,
  value,
  onChange,
  options,
}: {
  label: string;
  empty: string;
  value: string;
  onChange: (value: string) => void;
  options: [string, string][];
}) {
  const labels = new Map(options);
  const active = value !== "any";
  return (
    <Select value={value} onValueChange={(next) => onChange(next ?? value)}>
      <SelectTrigger
        aria-label={label}
        className={cn("w-44 shrink-0", active && "border-primary/40")}
      >
        <SelectValue>
          {(current: string) =>
            current === "any" ? empty : `${label}: ${labels.get(current)}`
          }
        </SelectValue>
      </SelectTrigger>
      <SelectContent>
        <SelectItem value="any">{empty}</SelectItem>
        {options.map(([key, text]) => (
          <SelectItem key={key} value={key}>
            {text}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}
