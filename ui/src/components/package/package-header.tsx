import type { ReactNode } from "react";
import type { ItemKind } from "@/bindings";
import { InlineMarkdown } from "@/components/inline-markdown";
import { PageHeader } from "@/components/page-header";
import { Badge } from "@/components/ui/badge";
import { FORKED_BADGE_LABEL } from "@/lib/copy";
import { kindIcon } from "@/lib/kind-icon";
import type { PlaceMark } from "@/lib/place-marks";
import { cn } from "@/lib/utils";

/** The package page's title block: what this is, what it says about itself,
 *  and the things you can do to it. */
export function PackageHeader({
  kind,
  displayName,
  description,
  forked,
  mark,
  action,
}: {
  kind: ItemKind;
  displayName: string;
  description: string | null;
  forked: boolean;
  mark: PlaceMark | null;
  action: ReactNode;
}) {
  const Icon = kindIcon(kind);
  return (
    <PageHeader
      wide
      title={
        // The icon centres on the text's own line box, not on the flex row:
        // a badge alongside makes the row taller than the words, and
        // centring against that visibly floats the icon off the title.
        <span className="flex items-baseline gap-2.5">
          <Icon
            className={cn(
              "size-5 shrink-0 translate-y-[0.1875rem]",
              // The same colour the Library row gives a customized
              // package's icon, so one package is marked one way.
              mark ? "text-customized" : "text-muted-foreground",
            )}
          />
          <span className="min-w-0 truncate">{displayName}</span>
          {forked ? (
            <Badge variant="outline">{FORKED_BADGE_LABEL}</Badge>
          ) : null}
        </span>
      }
      subtitle={
        mark || description ? (
          <>
            {/* Under the title and above the description, in words, the
                way the Library row carries it — not a pill beside the
                name. A badge there read as a property of the title; this
                is a sentence about the package. */}
            {mark ? <p className="mb-1 text-customized">{mark.label}</p> : null}
            {description ? <InlineMarkdown source={description} /> : null}
          </>
        ) : undefined
      }
      action={action}
    />
  );
}
