import type { ReactNode } from "react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { CUSTOMIZE_TAB, OVERVIEW_TAB } from "@/lib/copy-customize";

/** A package's two faces: what it is as installed, and what you have
 *  changed about it. Only some kinds carry an overlay at all, and a lone
 *  tab is a label pretending to be a choice — those pages are the overview
 *  and nothing else. */
export function PackageTabs({
  customizable,
  tab,
  onTabChange,
  overview,
  customize,
}: {
  customizable: boolean;
  tab: string;
  onTabChange: (tab: string) => void;
  overview: ReactNode;
  customize: ReactNode;
}) {
  if (!customizable) return overview;
  return (
    <Tabs value={tab} onValueChange={onTabChange}>
      <TabsList>
        <TabsTrigger value="overview">{OVERVIEW_TAB}</TabsTrigger>
        <TabsTrigger value="customize">{CUSTOMIZE_TAB}</TabsTrigger>
      </TabsList>
      <TabsContent value="overview" className="pt-6">
        {overview}
      </TabsContent>
      <TabsContent value="customize" className="pt-6">
        {customize}
      </TabsContent>
    </Tabs>
  );
}
