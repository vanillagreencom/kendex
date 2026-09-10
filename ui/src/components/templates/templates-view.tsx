import { useEffect, useMemo, useState } from "react";
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
import { type Template, useTemplatesStore } from "@/stores/templates";

/** How many of a template's members it keeps its own copy of. */
const copiesIn = (template: Template): number =>
  (template.members ?? []).filter((member) => member.source.held === "copy")
    .length;

/** "Templates": the saved selections, searchable, one row each.
 *
 *  Personal across projects, so there is no location filter here — the one
 *  narrowing is the search box, which is the one search box this tab has. */
export function TemplatesView() {
  const templates = useTemplatesStore((s) => s.templates);
  const read = useTemplatesStore((s) => s.read);
  const everRead = useTemplatesStore((s) => s.everRead);
  const load = useTemplatesStore((s) => s.load);
  const goToTemplate = useNavStore((s) => s.goToTemplate);
  const [search, setSearch] = useState("");

  useEffect(() => {
    void load();
  }, [load]);

  const shown = useMemo(() => {
    const wanted = search.trim().toLowerCase();
    if (wanted === "") return templates;
    return templates.filter((template) =>
      template.name.toLowerCase().includes(wanted),
    );
  }, [templates, search]);

  // A failed read with nothing behind it has no rows to draw and no wait
  // to draw either. One that failed over rows that landed keeps them,
  // headed as the last answer that came back rather than as current ones.
  const failedWithNothing = read.status === "failed" && !everRead;
  const reading = read.status === "reading" && !everRead;

  return (
    <div className={cn("flex min-h-0 flex-1 flex-col gap-4 pb-8", PAGE_GUTTER)}>
      <div className={cn("flex flex-col gap-3", WIDE_CONTENT_WIDTH)}>
        <Input
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder={TEMPLATES_SEARCH}
          aria-label={TEMPLATES_SEARCH}
          className="max-w-sm"
        />
        {read.status === "failed" ? (
          <div className="flex items-center gap-3">
            <p className="text-[13px] text-muted-foreground">
              {everRead ? TEMPLATES_LAST_KNOWN : TEMPLATES_UNREADABLE}
            </p>
            <Button size="sm" variant="outline" onClick={() => void load()}>
              {TRY_AGAIN_LABEL}
            </Button>
          </div>
        ) : null}
        {failedWithNothing || reading ? null : (
          <p className="text-[13px] text-muted-foreground">
            {TEMPLATES_EXPLAINER}
          </p>
        )}
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
            the read is done: a search that matches nothing is a different
            answer from a person with no templates. */}
        {!reading && !failedWithNothing && shown.length === 0 ? (
          <p className="py-2 text-sm text-muted-foreground">
            {templates.length === 0 ? TEMPLATES_EMPTY : TEMPLATES_NONE_MATCH}
          </p>
        ) : null}
      </div>
    </div>
  );
}
