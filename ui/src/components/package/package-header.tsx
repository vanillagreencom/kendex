import type { ReactNode } from "react";
import type { ItemKind, Scope } from "@/bindings";
import { InlineMarkdown } from "@/components/inline-markdown";
import { PageHeader } from "@/components/page-header";
import { Badge } from "@/components/ui/badge";
import { FORKED_BADGE_LABEL } from "@/lib/copy";
import { kindIcon } from "@/lib/kind-icon";
import type { PlaceMark } from "@/lib/place-marks";

/** The package page's title block: what this is, what it says about itself,
 *  and the things you can do to it. */
export function PackageHeader({
  kind,
  displayName,
  description,
  forked,
  mark,
  onOpenPlace,
  action,
}: {
  kind: ItemKind;
  displayName: string;
  description: string | null;
  forked: boolean;
  mark: PlaceMark | null;
  /** Open the place the mark names. */
  onOpenPlace: (scope: Scope) => void;
  action: ReactNode;
}) {
  const Icon = kindIcon(kind);
  // The place the mark names, bound once so the handler carries a scope
  // rather than a maybe-scope.
  const goTo = mark?.goTo ?? null;
  return (
    <PageHeader
      wide
      title={
        // The icon centres on the text's own line box, not on the flex row:
        // a badge alongside makes the row taller than the words, and
        // centring against that visibly floats the icon off the title.
        <span className="flex items-baseline gap-2.5">
          <Icon className="size-5 shrink-0 translate-y-[0.1875rem] text-muted-foreground" />
          <span className="min-w-0 truncate">{displayName}</span>
          {forked ? (
            <Badge variant="outline">{FORKED_BADGE_LABEL}</Badge>
          ) : null}
          {mark ? (
            // The mark names a place, so it goes there. A badge that names
            // a place and cannot be followed leaves the reader to find it.
            <Badge
              variant="customized"
              onClick={goTo ? () => onOpenPlace(goTo) : undefined}
              className={goTo ? "cursor-pointer" : undefined}
            >
              {mark.label}
            </Badge>
          ) : null}
        </span>
      }
      subtitle={
        description ? <InlineMarkdown source={description} /> : undefined
      }
      action={action}
    />
  );
}
