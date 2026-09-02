import { Plus, RefreshCw } from "lucide-react";
import { useEffect, useState } from "react";
import { CommunityTab } from "@/components/marketplaces/community-tab";
import { MineTab } from "@/components/marketplaces/mine-tab";
import { PackagesTab } from "@/components/marketplaces/packages-tab";
import { SubscribeDialog } from "@/components/marketplaces/subscribe-dialog";
import { SubscribedTab } from "@/components/marketplaces/subscribed-tab";
import { PageHeader } from "@/components/page-header";
import { Button } from "@/components/ui/button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { CHECK_FOR_UPDATES_LABEL } from "@/lib/copy";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { type MarketplacesTab, useNavStore } from "@/stores/nav";

export function MarketplacesPage() {
  const tab = useNavStore((s) => s.marketplacesTab);
  const goToMarketplaces = useNavStore((s) => s.goToMarketplaces);
  const load = useMarketplacesStore((s) => s.load);
  const checkForUpdates = useMarketplacesStore((s) => s.checkForUpdates);
  const busy = useMarketplacesStore((s) => s.busy);
  const [subscribeOpen, setSubscribeOpen] = useState(false);

  useEffect(() => {
    void load();
  }, [load]);

  return (
    <div className="flex h-full flex-col">
      <PageHeader
        title="Marketplaces"
        wide
        action={
          <>
            <Button size="sm" onClick={() => setSubscribeOpen(true)}>
              <Plus className="size-4" /> Subscribe…
            </Button>
            <Button
              size="sm"
              variant="outline"
              onClick={() => goToMarketplaces("mine")}
            >
              Create…
            </Button>
            {/* Refreshes every subscription, not one — so it belongs to
                the list rather than to a card or to whichever marketplace
                page happens to be open. */}
            <Button
              size="sm"
              variant="outline"
              disabled={busy}
              onClick={() => void checkForUpdates()}
            >
              <RefreshCw className={cn("size-4", busy && "animate-spin")} />
              {CHECK_FOR_UPDATES_LABEL}
            </Button>
          </>
        }
      />
      <SubscribeDialog open={subscribeOpen} onOpenChange={setSubscribeOpen} />
      <Tabs
        value={tab}
        onValueChange={(value) => goToMarketplaces(value as MarketplacesTab)}
        className="flex min-h-0 flex-1 flex-col gap-0"
      >
        <div className={cn("pb-6", PAGE_GUTTER)}>
          <div className={WIDE_CONTENT_WIDTH}>
            <TabsList>
              <TabsTrigger value="subscribed">Subscribed</TabsTrigger>
              <TabsTrigger value="packages">Packages</TabsTrigger>
              <TabsTrigger value="community">Community</TabsTrigger>
              <TabsTrigger value="mine">Mine</TabsTrigger>
            </TabsList>
          </div>
        </div>
        <TabsContent
          value="subscribed"
          className="min-h-0 flex-1 overflow-y-auto"
        >
          <SubscribedTab onSubscribe={() => setSubscribeOpen(true)} />
        </TabsContent>
        <TabsContent value="packages" className="flex min-h-0 flex-1 flex-col">
          <PackagesTab />
        </TabsContent>
        <TabsContent
          value="community"
          className="min-h-0 flex-1 overflow-y-auto"
        >
          <CommunityTab />
        </TabsContent>
        <TabsContent value="mine" className="min-h-0 flex-1 overflow-y-auto">
          <MineTab />
        </TabsContent>
      </Tabs>
    </div>
  );
}
