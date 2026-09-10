import { useEffect } from "react";
import { Toaster } from "sonner";
import { commands } from "@/bindings";
import { CommitOfferDialog } from "@/components/commit-offer-dialog";
import { ErrorDialog } from "@/components/error-dialog";
import { InstallDialog } from "@/components/install/install-dialog";
import { RepoEffectsDialog } from "@/components/marketplaces/repo-effects-dialog";
import { NavBar } from "@/components/nav-bar";
import { Sidebar } from "@/components/sidebar";
import { StatusFooter } from "@/components/status-footer";
import { TermsGate } from "@/components/terms-gate";
import { TooltipProvider } from "@/components/ui/tooltip";
import { WindowControls } from "@/components/window-controls";
import { receiveDeepLinks } from "@/lib/deep-link";
import { trackedProjects } from "@/lib/rescan";
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
import { ProjectChangesPage } from "@/pages/project-changes";
import { ProjectsPage } from "@/pages/projects";
import { SettingsPage } from "@/pages/settings";
import { TemplatePage } from "@/pages/template";
import { UnmanagedPage } from "@/pages/unmanaged";
import { UpdatesPage } from "@/pages/updates";
import { useAccountStore } from "@/stores/account";
import { useAuditStore } from "@/stores/audit";
import { useNavStore } from "@/stores/nav";
import { useNoticeStore } from "@/stores/notice";
import { useProjectChangesStore } from "@/stores/project-changes";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { useUpdatesStore } from "@/stores/updates";
import { zoom } from "@/stores/zoom";

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
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (zoom.onKeyDown(event)) event.preventDefault();
    };
    // Gives a size still inside its settle window its best chance rather
    // than a certain one: this starts the write instead of waiting out the
    // timer, and whether it lands depends on the runtime outliving the
    // unload.
    const onLeaving = () => zoom.flush();
    window.addEventListener("keydown", onKeyDown);
    window.addEventListener("beforeunload", onLeaving);
    return () => {
      window.removeEventListener("keydown", onKeyDown);
      window.removeEventListener("beforeunload", onLeaving);
      onLeaving();
    };
  }, []);
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

// A `kendex://` link is followed from here, once the page is up: a link
// that launched the app waits in the backend until this first effect asks
// for it, and a link clicked while the app runs arrives as an event. The
// listener may outlive a mount it was started under in StrictMode's
// double effect, so a stop that arrives after the unmount is used at once.
function useDeepLinks() {
  useEffect(() => {
    let stop: (() => void) | null = null;
    let unmounted = false;
    void receiveDeepLinks().then((unlisten) => {
      if (unmounted) unlisten();
      else stop = unlisten;
    });
    return () => {
      unmounted = true;
      stop?.();
    };
  }, []);
}

/** The reads the app starts with. Every one of them is owned here so a
 *  page that shows what they found subscribes instead of asking again. */
export function useStartupLoads() {
  const refresh = useScanStore((s) => s.refresh);
  const auditRefresh = useAuditStore((s) => s.refresh);
  const updatesLoad = useUpdatesStore((s) => s.reload);
  const load = useSettingsStore((s) => s.load);
  const reloadSettings = useSettingsStore((s) => s.reload);
  const noticeLoad = useNoticeStore((s) => s.load);
  const accountLoad = useAccountStore((s) => s.load);
  const scanGeneration = useScanStore((s) => s.generation);
  const ensurePackages = useProvenanceStore((s) => s.ensureFor);
  // What each project has waiting for a commit. Read here rather than by
  // the pages that show it — the Projects page's cards, a project's own
  // view and the review page all draw the same fact — and keyed on the
  // tracked list, because that list arrives with the settings read and a
  // read started before it would have covered no projects at all. It opens
  // nothing: a passive read of a git checkout, and no dialog anywhere is
  // reachable from it.
  const projects = useSettingsStore((s) => s.settings?.projects);
  const readProjectChanges = useProjectChangesStore((s) => s.refresh);
  useEffect(() => {
    if (!projects) return;
    void readProjectChanges(projects);
  }, [projects, readProjectChanges]);
  // Which observations are one package is read here rather than by the
  // pages that show packages: the Library table, Home's Installed tile and
  // every place's badges all count in that unit, and a page asking for
  // itself would have each of them counting from a different answer.
  // Re-joined whenever a scan lands, so an install or unsubscribe made
  // elsewhere reaches every one of them without a manual refresh. Through
  // the same coordinator the rescan uses, so a scan that rescan published
  // is read once rather than twice.
  useEffect(() => {
    if (scanGeneration === 0) return;
    void ensurePackages(scanGeneration);
  }, [ensurePackages, scanGeneration]);
  useEffect(() => {
    // Independent reads, started together: the audit is the slow one
    // (it scores every installed file), and chaining it behind the scan
    // would leave the Library sitting empty waiting on work it does not
    // need.
    void load();
    void refresh();
    void auditRefresh();
    void updatesLoad();
    void accountLoad();
    // The app's own release check, read once a session: the backend keeps
    // the answer and contacts the feed at most six-hourly, so a re-read on
    // every focus would tell the card nothing it does not already say.
    void noticeLoad();
    let last = Date.now();
    const onFocus = () => {
      if (Date.now() - last < FOCUS_RESCAN_DEBOUNCE_MS) return;
      last = Date.now();
      void refresh();
      // The settings file is machine-local and the CLI writes it too: a
      // `kendex add` in a terminal registers the folder it installed
      // into, and the scan behind `refresh` reads that registry itself.
      // Without this the scan would find the new project's packages while
      // the Projects page went on drawing the list from before it. The
      // registry alone is re-read, and nothing here asks a project what
      // to do with its uncommitted files: a command run in a terminal is
      // not a reason to put a question on screen in the app.
      void reloadSettings();
      // An update or edit could have landed while the window was away —
      // the badge should notice without a visit to the page. The audit is
      // forced along with it: an editor saving a skill while the app was
      // out of focus is exactly the change every score on screen is now
      // wrong about, and the freshness window would hold the old one. A
      // terminal can sign in or out while the window is away too, and a
      // read that failed at launch gets its next try here.
      void updatesLoad();
      void auditRefresh({ force: true });
      void accountLoad();
      // Somebody can commit, stash or edit in a terminal while the window
      // is away, so what is waiting here is exactly the fact focus has to
      // re-read. It still opens nothing.
      void useProjectChangesStore.getState().refresh(trackedProjects());
    };
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [
    refresh,
    auditRefresh,
    updatesLoad,
    load,
    reloadSettings,
    noticeLoad,
    accountLoad,
  ]);
}

export default function App() {
  useAppearance();
  useStartupLoads();
  useDeepLinks();
  useMouseNavigation();
  useZoomShortcuts();
  const page = useNavStore((s) => s.page);
  const packageRef = useNavStore((s) => s.packageRef);
  const packageKey = packageRef
    ? `${packageRef.kind}:${packageRef.name}:${packageRef.scope.scope === "global" ? "global" : packageRef.scope.root}`
    : "none";
  // Keyed like the package page: opening another template remounts, so no
  // read from the one before it can land on the one now open.
  const templateName = useNavStore((s) => s.templateName) ?? "none";
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
        {/* The one guided install, opened by every Install in the app. It
            lives here rather than on a page so the same flow answers a
            package page, a set, a table row and a project's Add packages. */}
        <InstallDialog />
        <RepoEffectsDialog />
        {/* The question a write leaves behind: what to do with the files
            kendex wrote in a git project. */}
        <CommitOfferDialog />
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
                {page === "template" && <TemplatePage key={templateName} />}
                {page === "marketplaces" && <MarketplacesPage />}
                {page === "marketplaceDetail" && <MarketplaceDetailPage />}
                {page === "bundleDetail" && <BundleDetailPage />}
                {page === "availablePackage" && <AvailablePackagePage />}
                {page === "updates" && <UpdatesPage />}
                {page === "harnesses" && <HarnessesPage />}
                {page === "projects" && <ProjectsPage />}
                {page === "projectChanges" && <ProjectChangesPage />}
                {page === "unmanaged" && <UnmanagedPage />}
                {page === "customize" && <CustomizePage />}
                {page === "settings" && <SettingsPage />}
                {page === "problems" && <ProblemsPage />}
              </div>
            </div>
          </main>
        </div>
        <StatusFooter />
        {/* Last, and over everything: the first thing a new install shows.
            It records an answer and gets out of the way — nothing else in
            the app waits on it. */}
        <TermsGate />
      </div>
    </TooltipProvider>
  );
}
