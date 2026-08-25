import type { ReactNode } from "react";
import type { HarnessId, ItemKind, Scope } from "@/bindings";
import { ItemCustomize } from "@/components/customize/item-customize";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { CUSTOMIZE_TAB, OVERVIEW_TAB } from "@/lib/copy-customize";
import { canCustomize } from "@/lib/customization";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { cn } from "@/lib/utils";

/** The package page's scrolling content: the package's own body, and — for
 *  a kind whose rendering the person can shape — the customize tab beside
 *  it. A kind with nothing to customize gets the body alone rather than a
 *  tab strip with one tab in it. */
export function PackageTabs({
  kind,
  name,
  scopes,
  harnesses,
  body,
}: {
  kind: ItemKind;
  name: string;
  scopes: Scope[];
  harnesses: HarnessId[];
  body: ReactNode;
}) {
  return (
    <div className={cn("min-h-0 flex-1 overflow-y-auto", PAGE_GUTTER)}>
      <div className={cn("pb-8", WIDE_CONTENT_WIDTH)}>
        {canCustomize(kind) ? (
          <Tabs defaultValue="overview">
            <TabsList>
              <TabsTrigger value="overview">{OVERVIEW_TAB}</TabsTrigger>
              <TabsTrigger value="customize">{CUSTOMIZE_TAB}</TabsTrigger>
            </TabsList>
            <TabsContent value="overview" className="pt-6">
              {body}
            </TabsContent>
            <TabsContent value="customize" className="pt-6">
              <ItemCustomize
                kind={kind}
                name={name}
                scopes={scopes}
                harnesses={harnesses}
              />
            </TabsContent>
          </Tabs>
        ) : (
          body
        )}
      </div>
    </div>
  );
}
