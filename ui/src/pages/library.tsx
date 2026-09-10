import { BookmarksView } from "@/components/bookmarks/bookmarks-view";
import { InstalledView } from "@/components/library/installed-view";
import { PageHeader } from "@/components/page-header";
import { TemplatesView } from "@/components/templates/templates-view";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { BOOKMARKS_TAB } from "@/lib/copy-bookmarks";
import { INSTALLED_TAB, TEMPLATES_TAB } from "@/lib/copy-templates";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { type LibraryTab, useNavStore } from "@/stores/nav";

// My Library, in three tabs. Installed is what is on this machine and
// keeps its location filter; Templates is the person's saved selections and
// Bookmarks the marketplace items they saved to find again, both of which
// belong to no place and so have no location to filter by.
export function LibraryPage() {
  const tab = useNavStore((s) => s.libraryTab);
  const setTab = useNavStore((s) => s.setLibraryTab);
  return (
    <div className="flex h-full flex-col">
      <PageHeader title="My Library" wide />
      <Tabs
        value={tab}
        onValueChange={(value) => setTab(value as LibraryTab)}
        className="flex min-h-0 flex-1 flex-col gap-0"
      >
        <div className={cn("pb-6", PAGE_GUTTER)}>
          <div className={WIDE_CONTENT_WIDTH}>
            <TabsList>
              <TabsTrigger value="installed">{INSTALLED_TAB}</TabsTrigger>
              <TabsTrigger value="templates">{TEMPLATES_TAB}</TabsTrigger>
              <TabsTrigger value="bookmarks">{BOOKMARKS_TAB}</TabsTrigger>
            </TabsList>
          </div>
        </div>
        <TabsContent value="installed" className="flex min-h-0 flex-1 flex-col">
          <InstalledView />
        </TabsContent>
        <TabsContent
          value="templates"
          className="flex min-h-0 flex-1 flex-col overflow-y-auto"
        >
          <TemplatesView />
        </TabsContent>
        <TabsContent
          value="bookmarks"
          className="flex min-h-0 flex-1 flex-col overflow-y-auto"
        >
          <BookmarksView />
        </TabsContent>
      </Tabs>
    </div>
  );
}
