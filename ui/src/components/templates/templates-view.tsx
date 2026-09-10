import { useEffect, useMemo, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  TEMPLATES_EMPTY,
  TEMPLATES_EXPLAINER,
  TEMPLATES_LAST_KNOWN,
  TEMPLATES_NONE_MATCH,
  TEMPLATES_SEARCH,
  TEMPLATES_UNREADABLE,
  templateSummary,
} from "@/lib/copy-templates";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { opensLabel, opensOnActivate } from "@/lib/opens-on-activate";
import { cn } from "@/lib/utils";
import { useNavStore } from "@/stores/nav";
import {
  type Template,
  useTemplatesAnswer,
  useTemplatesStore,
} from "@/stores/templates";

/** The rows an answer with none has, as one value rather than a fresh
 *  array per render. */
const NO_TEMPLATES: Template[] = [];

/** How many of a template's members it keeps its own copy of. */
const copiesIn = (template: Template): number =>
  (template.members ?? []).filter((member) => member.source.held === "copy")
    .length;

/** "Templates": the saved selections, searchable, one row each.
 *
 *  Personal across projects, so there is no location filter here — the one
 *  narrowing is the search box, which is the one search box this tab has. */
export function TemplatesView() {
  const answer = useTemplatesAnswer();
  const load = useTemplatesStore((s) => s.load);
  const goToTemplate = useNavStore((s) => s.goToTemplate);
  const searchFocus = useNavStore((s) => s.searchFocus);
  const [search, setSearch] = useState("");
  const searchRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    void load();
  }, [load]);

  // The one search box this tab has, on the app's own shortcut. The "/"
  // shortcut fires from any page, so it bumps a counter rather than
  // reaching for a box that may not be mounted when it fires — the same
  // counter the Installed tab's box and the Marketplaces one read, so
  // whichever box is on screen is the one that takes the focus.
  useEffect(() => {
    if (searchFocus === 0) return;
    searchRef.current?.focus();
    searchRef.current?.select();
  }, [searchFocus]);

  // The rows this answer has, which is none for the two states that have
  // none: a wait and a read that failed with nothing behind it draw no
  // list and make no claim about one.
  const held =
    answer.shown === "waiting" || answer.shown === "unreadable"
      ? NO_TEMPLATES
      : answer.templates;
  const shown = useMemo(() => {
    const wanted = search.trim().toLowerCase();
    if (wanted === "") return held;
    return held.filter((template) =>
      template.name.toLowerCase().includes(wanted),
    );
  }, [held, search]);

  // Whether this answer has anything to say about what is saved. Neither
  // a wait nor an unreadable index does, so neither the explainer nor any
  // empty state is drawn over one.
  const answered = answer.shown === "read" || answer.shown === "lastKnown";

  return (
    <div className={cn("flex min-h-0 flex-1 flex-col gap-4 pb-8", PAGE_GUTTER)}>
      <div className={cn("flex flex-col gap-3", WIDE_CONTENT_WIDTH)}>
        <Input
          ref={searchRef}
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder={TEMPLATES_SEARCH}
          aria-label={TEMPLATES_SEARCH}
          className="max-w-sm"
        />
        {answer.shown === "unreadable" || answer.shown === "lastKnown" ? (
          <div className="flex items-center gap-3">
            <p className="text-[13px] text-muted-foreground">
              {answer.shown === "lastKnown"
                ? TEMPLATES_LAST_KNOWN
                : TEMPLATES_UNREADABLE}
            </p>
            <Button size="sm" variant="outline" onClick={() => void load()}>
              {TRY_AGAIN_LABEL}
            </Button>
          </div>
        ) : null}
        {answered ? (
          <p className="text-[13px] text-muted-foreground">
            {TEMPLATES_EXPLAINER}
          </p>
        ) : null}
      </div>
      <div
        className={cn("flex min-h-0 flex-1 flex-col gap-2", WIDE_CONTENT_WIDTH)}
      >
        {shown.map((template) => (
          <Card
            key={template.name}
            {...opensOnActivate(
              () => goToTemplate(template.name),
              opensLabel(template.name),
            )}
            className="cursor-pointer gap-1 px-4 py-3 hover:bg-accent/40"
          >
            <button
              type="button"
              className="w-full cursor-pointer truncate text-left text-sm font-medium"
              onClick={() => goToTemplate(template.name)}
            >
              {template.name}
            </button>
            <p className="truncate text-[13px] text-muted-foreground">
              {templateSummary(
                (template.members ?? []).length,
                copiesIn(template),
              )}
            </p>
          </Card>
        ))}
        {/* An empty state only where the list would otherwise be blank and
            a read has answered: a search that matches nothing is a
            different answer from a person with no templates, and a read
            that has not landed is neither. */}
        {answered && shown.length === 0 ? (
          <p className="py-2 text-sm text-muted-foreground">
            {held.length === 0 ? TEMPLATES_EMPTY : TEMPLATES_NONE_MATCH}
          </p>
        ) : null}
      </div>
    </div>
  );
}
