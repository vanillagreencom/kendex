import type { ReactNode } from "react";
import type { ItemKind, Scope } from "@/bindings";
import { InlineMarkdown } from "@/components/inline-markdown";
import { PageHeader } from "@/components/page-header";
import { Badge } from "@/components/ui/badge";
import { customizedInLabel, forkedInLabel } from "@/lib/copy-customize";
import type { PlaceStanding } from "@/lib/customized-places";
import { kindIcon } from "@/lib/kind-icon";
import { scopeName } from "@/lib/labels";

/** The package page's title block: what this is, what it says about itself,
 *  and the things you can do to it. */
export function PackageHeader({
  kind,
  displayName,
  description,
  place,
  scopes,
  action,
}: {
  kind: ItemKind;
  displayName: string;
  description: string | null;
  /** The place both marks are about — the one the Customize tab has open,
   *  or null while the page is still working out which that is. One value,
   *  so the badges can never disagree about which place they describe. */
  place: PlaceStanding | null;
  /** Every place this package lives in, so two projects sharing a folder
   *  name are named apart. */
  scopes: Scope[];
  action: ReactNode;
}) {
  const Icon = kindIcon(kind);
  const named = place ? scopeName(place.scope, scopes) : null;
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
          {place?.forked && named ? (
            // Named in the badge itself, not only in a tooltip: a mark that
            // says which place it is about says nothing to anyone reading
            // by touch or by keyboard if the place is only on hover.
            <Badge variant="outline">{forkedInLabel([named])}</Badge>
          ) : null}
          {place?.state === "customized" && named ? (
            <Badge variant="customized">{customizedInLabel(named)}</Badge>
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
