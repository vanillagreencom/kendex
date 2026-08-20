import { useEffect } from "react";
import { Toaster } from "sonner";
import { commands, ZOOM } from "@/bindings";
import { ErrorDialog } from "@/components/error-dialog";
import { NavBar } from "@/components/nav-bar";
import { Sidebar } from "@/components/sidebar";
import { StatusFooter } from "@/components/status-footer";
import { TooltipProvider } from "@/components/ui/tooltip";
import { WindowControls } from "@/components/window-controls";
import { zoomControls } from "@/lib/zoom-controls";
import { AvailablePackagePage } from "@/pages/available-package";
import { BundleDetailPage } from "@/pages/bundle-detail";
import { CustomizePage } from "@/pages/customize";
import { HarnessesPage } from "@/pages/harnesses";
import { LibraryPage } from "@/pages/library";
import { MarketplaceDetailPage } from "@/pages/marketplace-detail";
import { MarketplacesPage } from "@/pages/marketplaces";
import { OverviewPage } from "@/pages/overview";
import { PackagePage } from "@/pages/package";
import { ProblemsPage } from "@/pages/problems";
import { ProjectsPage } from "@/pages/projects";
import { ReviewPage } from "@/pages/review";
import { SettingsPage } from "@/pages/settings";
import { UnmanagedPage } from "@/pages/unmanaged";
import { UpdatesPage } from "@/pages/updates";
import { useAuditStore } from "@/stores/audit";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { useUpdatesStore } from "@/stores/updates";

const FOCUS_RESCAN_DEBOUNCE_MS = 5000;

function useAppearance() {
  const appearance = useSettingsStore(
    (s) => s.settings?.appearance ?? "system",
  );
  useEffect(() => {
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const apply = () => {
      const dark =
        appearance === "dark" || (appearance === "system" && media.matches);
      document.documentElement.classList.toggle("dark", dark);
    };
    apply();
    media.addEventListener("change", apply);
    return () => media.removeEventListener("change", apply);
  }, [appearance]);
}

// Ctrl and + or - resize the whole app, the way they resize a page in a
// browser. The keys work anywhere, fields included, because that is where a
// browser's zoom works too.
function useZoomShortcuts() {
  const setZoom = useSettingsStore((s) => s.setZoom);
  const saveZoom = useSettingsStore((s) => s.saveZoom);
  useEffect(() => {
    const zoom = zoomControls(setZoom, saveZoom);
    const onKeyDown = (event: KeyboardEvent) => {
      const current =
        useSettingsStore.getState().settings?.zoom ?? ZOOM.default;
      if (zoom.onKeyDown(event, current)) event.preventDefault();
    };
    window.addEventListener("keydown", onKeyDown);
    // This effect ends with the app, so a write still waiting on the settle
    // would be talking to a window that is going away.
    return () => {
      zoom.cancel();
      window.removeEventListener("keydown", onKeyDown);
    };
  }, [setZoom, saveZoom]);
}

// The side buttons on a mouse mean back and forward everywhere else on the
// desktop, so they mean it here too. The webview has no history of its own
// to move through, so nothing else would happen if we left them alone.
function useMouseNavigation() {
  const back = useNavStore((s) => s.back);
  const forward = useNavStore((s) => s.forward);
  useEffect(() => {
    const onMouseUp = (event: MouseEvent) => {
      if (event.button !== 3 && event.button !== 4) return;
      event.preventDefault();
      if (event.button === 3) back();
      else forward();
    };
    // Chromium fires auxclick for these too; swallowing it stops a stray
    // click landing on whatever sits under the cursor after the page swaps.
    const swallow = (event: MouseEvent) => {
      if (event.button === 3 || event.button === 4) event.preventDefault();
    };
    window.addEventListener("mouseup", onMouseUp);
    window.addEventListener("auxclick", swallow);
    return () => {
      window.removeEventListener("mouseup", onMouseUp);
      window.removeEventListener("auxclick", swallow);
    };
  }, [back, forward]);
}

function useScanTriggers() {
  const refresh = useScanStore((s) => s.refresh);
  const auditRefresh = useAuditStore((s) => s.refresh);
  const updatesLoad = useUpdatesStore((s) => s.load);
  const load = useSettingsStore((s) => s.load);
  useEffect(() => {
    // Four independent reads, started together: the audit is the slow one
    // (it scores every installed file), and chaining it behind the scan
    // meant the Library sat empty waiting on work it does not need.
    void load();
    void refresh();
    void auditRefresh();
    void updatesLoad();
    let last = Date.now();
    const onFocus = () => {
      if (Date.now() - last < FOCUS_RESCAN_DEBOUNCE_MS) return;
      last = Date.now();
      void refresh();
      // An update or edit could have landed while the window was away —
      // the badge should notice without a visit to the page.
      void updatesLoad();
    };
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [refresh, auditRefresh, updatesLoad, load]);
}

export default function App() {
  useAppearance();
  useScanTriggers();
  useMouseNavigation();
  useZoomShortcuts();
  const page = useNavStore((s) => s.page);
  const packageRef = useNavStore((s) => s.packageRef);
  const packageKey = packageRef
    ? `${packageRef.kind}:${packageRef.name}:${packageRef.scope.scope === "global" ? "global" : packageRef.scope.root}`
    : "none";
  const appearance = useSettingsStore(
    (s) => s.settings?.appearance ?? "system",
  );

  return (
    <TooltipProvider delay={300}>
      <div className="flex h-screen flex-col overflow-hidden bg-background text-foreground">
        <Toaster
          theme={appearance}
          position="bottom-right"
          offset={{ bottom: "2rem" }}
          toastOptions={{
            classNames: {
              toast:
                "!bg-popover !text-popover-foreground !border-border !shadow-lg",
              title: "!text-sm !font-medium",
              description: "!text-muted-foreground",
              actionButton: "!bg-primary !text-primary-foreground",
              cancelButton: "!bg-muted !text-muted-foreground",
            },
          }}
        />
        <ErrorDialog />
        <div className="flex flex-1 overflow-hidden">
          <Sidebar />
          <main className="relative flex flex-1 flex-col overflow-hidden">
            {/* biome-ignore lint/a11y/noStaticElementInteractions: double-click here is a convenience alias for the maximize button already on screen */}
            <div
              data-tauri-drag-region
              onDoubleClick={() => void commands.windowToggleMaximize()}
              className="absolute inset-x-0 top-0 h-8"
            />
            <WindowControls className="absolute top-0 right-0 z-20" />
            {/* Above the drag strip so nothing real content renders ever sits
              under it, no matter which page or nav state is showing. */}
            <div className="relative z-10 flex flex-1 flex-col overflow-hidden">
              <NavBar />
              <div className="flex-1 overflow-y-auto">
                {page === "home" && <OverviewPage />}
                {page === "library" && <LibraryPage />}
                {page === "package" && <PackagePage key={packageKey} />}
                {page === "marketplaces" && <MarketplacesPage />}
                {page === "marketplaceDetail" && <MarketplaceDetailPage />}
                {page === "bundleDetail" && <BundleDetailPage />}
                {page === "availablePackage" && <AvailablePackagePage />}
                {page === "updates" && <UpdatesPage />}
                {page === "harnesses" && <HarnessesPage />}
                {page === "projects" && <ProjectsPage />}
                {page === "unmanaged" && <UnmanagedPage />}
                {page === "review" && <ReviewPage />}
                {page === "customize" && <CustomizePage />}
                {page === "settings" && <SettingsPage />}
                {page === "problems" && <ProblemsPage />}
              </div>
            </div>
          </main>
        </div>
        <StatusFooter />
      </div>
    </TooltipProvider>
  );
}
