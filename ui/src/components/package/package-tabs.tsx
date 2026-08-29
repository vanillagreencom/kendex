import type { ReactNode } from "react";
import type { HarnessId, ItemKind, Scope } from "@/bindings";
import { ItemCustomize } from "@/components/customize/item-customize";
import { PackageProjects } from "@/components/package/package-projects";
import {
  PackageSafety,
  SafetyScoreLabel,
  usePackageSafety,
} from "@/components/package/package-safety";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { CUSTOMIZE_TAB, OVERVIEW_TAB } from "@/lib/copy-customize";
import { PROJECTS_TAB } from "@/lib/copy-projects";
import { canCustomize } from "@/lib/customization";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { cn } from "@/lib/utils";

/** The package page's scrolling content: what the package is, the places it
 *  is installed in, what the safety check made of it, and — for a kind whose
 *  rendering the person can shape — what they have changed about it.
 *
 *  Customize is last because it is the only tab a package kind can lack,
 *  so every other tab keeps its position whatever the package is. */
export function PackageTabs({
  kind,
  name,
  scope,
  scopes,
  harnesses,
  busy,
  onDelete,
  body,
}: {
  kind: ItemKind;
  name: string;
  /** The one place this page is about. The score answers for the copy
   *  installed there, which is the copy the rest of the page describes. */
  scope: Scope;
  scopes: Scope[];
  harnesses: HarnessId[];
  busy: boolean;
  /** Opens the dialog that deletes every copy — the Projects tab offers
   *  the whole-package deletion beside its per-place removals, and one
   *  dialog confirms it wherever it was asked for. */
  onDelete: () => void;
  body: ReactNode;
}) {
  // Read once here rather than in each of the two places it shows: the tab
  // and its panel are one claim, and two readings could disagree.
  const safety = usePackageSafety(kind, name, scope);
  const customizable = canCustomize(kind);
  return (
    <div className={cn("min-h-0 flex-1 overflow-y-auto", PAGE_GUTTER)}>
      <div className={cn("pb-8", WIDE_CONTENT_WIDTH)}>
        <Tabs defaultValue="overview">
          <TabsList>
            <TabsTrigger value="overview">{OVERVIEW_TAB}</TabsTrigger>
            <TabsTrigger value="projects">{PROJECTS_TAB}</TabsTrigger>
            <TabsTrigger value="safety">
              <SafetyScoreLabel reading={safety} />
            </TabsTrigger>
            {customizable ? (
              <TabsTrigger value="customize">{CUSTOMIZE_TAB}</TabsTrigger>
            ) : null}
          </TabsList>
          <TabsContent value="overview" className="pt-6">
            {body}
          </TabsContent>
          <TabsContent value="projects" className="pt-6">
            <PackageProjects
              kind={kind}
              name={name}
              scopes={scopes}
              busy={busy}
              onDelete={onDelete}
            />
          </TabsContent>
          <TabsContent value="safety" className="pt-6">
            <PackageSafety reading={safety} />
          </TabsContent>
          {customizable ? (
            <TabsContent value="customize" className="pt-6">
              <ItemCustomize
                kind={kind}
                name={name}
                scopes={scopes}
                harnesses={harnesses}
              />
            </TabsContent>
          ) : null}
        </Tabs>
      </div>
    </div>
  );
}
