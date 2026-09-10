import type { ReactNode } from "react";
import type { HarnessId, ItemKind, ObservedItem, Scope } from "@/bindings";
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
  installations,
  declares,
  scope,
  scopes,
  harnesses,
  vendor,
  busy,
  openOn,
  onDelete,
  body,
}: {
  kind: ItemKind;
  name: string;
  /** The one place this page is about. The score answers for the copy
   *  installed there, which is the copy the rest of the page describes. */
  scope: Scope;
  scopes: Scope[];
  /** This package's installations, as the Library grouped them — what each
   *  tool stores it as is an installation detail, not a second identity. */
  installations: ObservedItem[];
  /** Whether this page has a declaration behind it. The tabs that read or
   *  write one are absent where it has not. */
  declares: boolean;
  harnesses: HarnessId[];
  /** Who ships the copy at `scope`, when a tool ships it itself. The audit
   *  never reads such a package, so its tab says so instead of offering a
   *  check that will not come. Read off the one installation this page is
   *  about, the same copy the score would have answered for. */
  vendor: string | null;
  busy: boolean;
  /** Which tab the page opens on. A safety score anywhere in the app is
   *  the way to the findings under it, and they live on the Safety tab, so
   *  the link that opened this page says which tab it meant. */
  openOn: "overview" | "safety";
  /** Opens the dialog that deletes every copy — the Projects tab offers
   *  the whole-package deletion beside its per-place removals, and one
   *  dialog confirms it wherever it was asked for. */
  /** Absent where this page addresses no declaration. */
  onDelete?: () => void;
  body: ReactNode;
}) {
  // Read once here rather than in each of the two places it shows: the tab
  // and its panel are one claim, and two readings could disagree.
  // Keyed by scope, kind and name like the rest: asked for a page with no
  // declaration behind it, it would report the other package's score.
  const safety = usePackageSafety(declares ? kind : null, name, scope);
  // Only a page with a declaration behind it has these. Projects reads
  // each place's record and offers that declaration's update and removal;
  // Customize edits its manifest. On a page about an installation nothing
  // recorded, the same scope, kind and name may belong to a package that
  // IS recorded, so both would read and write that one.
  const customizable = declares && canCustomize(kind);
  return (
    <div className={cn("min-h-0 flex-1 overflow-y-auto", PAGE_GUTTER)}>
      <div className={cn("pb-8", WIDE_CONTENT_WIDTH)}>
        <Tabs defaultValue={openOn}>
          <TabsList>
            <TabsTrigger value="overview">{OVERVIEW_TAB}</TabsTrigger>
            {declares ? (
              <TabsTrigger value="projects">{PROJECTS_TAB}</TabsTrigger>
            ) : null}
            <TabsTrigger value="safety">
              <SafetyScoreLabel reading={safety} vendor={vendor} />
            </TabsTrigger>
            {customizable ? (
              <TabsTrigger value="customize">{CUSTOMIZE_TAB}</TabsTrigger>
            ) : null}
          </TabsList>
          <TabsContent value="overview" className="pt-6">
            {body}
          </TabsContent>
          {declares ? (
            <TabsContent value="projects" className="pt-6">
              <PackageProjects
                kind={kind}
                name={name}
                scopes={scopes}
                installations={installations}
                busy={busy}
                onDelete={onDelete}
              />
            </TabsContent>
          ) : null}
          <TabsContent value="safety" className="pt-6">
            <PackageSafety reading={safety} vendor={vendor} />
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
