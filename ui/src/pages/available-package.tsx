import { useState } from "react";
import { commands, type PackageView } from "@/bindings";
import { FileBrowser } from "@/components/files/file-browser";
import { packageFileEntries } from "@/components/files/package-file-rows";
import { MarkdownView } from "@/components/markdown-view";
import { AvailableAside } from "@/components/marketplaces/available-aside";
import { CatalogFilePreview } from "@/components/marketplaces/catalog-file-preview";
import { RecordsUnreadableNote } from "@/components/marketplaces/packages-trouble";
import { RepoAction } from "@/components/marketplaces/repo-action";
import { useCatalog } from "@/components/marketplaces/use-catalog";
import { SummaryText } from "@/components/package/summary-text";
import { PageHeader } from "@/components/page-header";
import { SafetyPanel } from "@/components/safety-panel";
import { SectionHeading } from "@/components/section";
import { TagBadges } from "@/components/tag-badge";
import { Button } from "@/components/ui/button";
import {
  FILE_TREE_LABEL,
  FILES_TAB,
  NO_README_NOTE,
  PICK_A_FILE_NOTE,
} from "@/lib/copy-files";
import { INSTALL_ACTION, justThisLabel } from "@/lib/copy-install";
import { recordsUnreadable } from "@/lib/install-state";
import { kindIcon } from "@/lib/kind-icon";
import { kindLabel, packageDisplayName } from "@/lib/labels";
import { PAGE_BODY, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { sourceLine } from "@/lib/marketplace-display";
import { useOrderedRead } from "@/lib/use-ordered-read";
import { cn } from "@/lib/utils";
import { useInstallFlow } from "@/stores/install-flow";
import { catalogKey, useMarketplacesStore } from "@/stores/marketplaces";
import { type AvailableRef, useNavStore } from "@/stores/nav";

/** A package that isn't installed yet: what it is, its own README, its
 * files, and the safety findings its bytes earn before anything lands.
 * From a repository nobody subscribes to yet, the one action is Subscribe;
 * installing turns this same address into the installed package's page. */
export function AvailablePackagePage() {
  const availableRef = useNavStore((s) => s.availableRef);
  if (!availableRef) return null;
  return <AvailablePackage availableRef={availableRef} />;
}

function AvailablePackage({ availableRef }: { availableRef: AvailableRef }) {
  const { kind, name } = availableRef;
  const {
    catalog,
    summary,
    display,
    error: reachError,
    ready,
  } = useCatalog(availableRef.catalog);
  // KEN-1282's navigation off this page stays; the page no longer sends an
  // install of its own, so `goToPackage` and the store's `install` go with
  // it — the guided flow owns both, and it says where the packages went.
  const goToMarketplace = useNavStore((s) => s.goToMarketplace);
  const goToBundle = useNavStore((s) => s.goToBundle);
  const busy = useMarketplacesStore((s) => s.busy);
  const openInstall = useInstallFlow((s) => s.open);

  const scope = catalog.by === "subscription" ? catalog.scope : null;

  // Null until the catalog is ready: a repository's first fetch holds the
  // store's lock, and a read racing it would be refused. The read is of
  // the place this package is offered in; where it lands is the guided
  // flow's question, asked after this page has said what the package is.
  const address = ready ? `${catalogKey(catalog)}::${kind}::${name}` : null;
  const read = useOrderedRead<PackageView>(address, () =>
    commands.marketplacePackagePreview(catalog, kind, name, null),
  );
  const view = read.status === "ok" ? read.data : null;
  const error = read.status === "error" ? read.error : null;

  // The chosen file carries the address it was chosen under, so a move to
  // another package shows that package's files rather than a path from the
  // one before it.
  const [chosen, setChosen] = useState<{ at: string; file: string } | null>(
    null,
  );
  const selectedFile = chosen?.at === address ? chosen.file : null;
  const selectFile = (file: string) =>
    setChosen(address === null ? null : { at: address, file });

  const Icon = kindIcon(kind);
  // What the marketplace calls itself and where it comes from, from the one
  // resolution `useCatalog` makes: it holds the summary that discovered this
  // subscription, which is cached under the repository this page was opened
  // by and so is lost to anything looking it up by the catalog it was
  // handed. Never the declaration's own `path` either — `.` is what the
  // person typed, and it reads as the app's own folder wherever it shows.
  const marketplace = display.name;
  const repo = sourceLine(display) || null;
  const shownError = reachError ?? error;
  // Every Packages row opens this page, "Not known" ones included. The
  // engine answered unknown because it could not read the lock of the place
  // this package is offered in, and an install starting from here would
  // meet that same record — so the page says why in place of the button
  // rather than letting a raw engine error stand in for the reason.
  const recordsUnknown = view !== null && recordsUnreadable(view.preview.state);

  // The tree's rows say what the installed package's Files tab says about
  // the same files, through the same mapper: each file's size, and the
  // readme marker on the one the preview opens on.
  const fileEntries = packageFileEntries(view?.preview.files ?? []);

  const doInstall = () => {
    if (catalog.by !== "subscription") return;
    const shown = packageDisplayName({ kind, name });
    openInstall({
      subjects: [
        {
          id: `${kind}:${name}`,
          label: justThisLabel(shown),
          what: shown,
          count: 1,
          groups: [
            {
              source: catalog.source,
              browsing: catalog.scope,
              items: [{ kind, name }],
              bundle: null,
            },
          ],
          kinds: [kind],
          dependencies: view?.preview.dependencies,
        },
      ],
    });
  };

  return (
    <div className="flex h-full flex-col">
      <PageHeader
        wide
        title={
          <span className="flex items-center gap-2.5">
            <Icon className="size-6 text-muted-foreground" />
            {packageDisplayName({ kind, name })}
          </span>
        }
        subtitle={
          <>
            {/* The same words the catalogue row shows and the Library
                row will show once it is installed: one package version,
                one description of it. */}
            {view?.preview.summary ? (
              <SummaryText summary={view.preview.summary} />
            ) : null}
            <span className="mt-1 flex items-center gap-2">
              <span className="text-xs">{kindLabel(kind)}</span>
              <TagBadges tags={view?.preview.tags ?? []} />
            </span>
          </>
        }
        action={
          catalog.by === "repo" ? (
            <RepoAction
              repo={catalog.repo}
              summary={summary}
              subscribeLabel="Subscribe to install"
            />
          ) : scope ? (
            // One button, because there is one action. What goes where is
            // the guided flow's two questions, asked in one place behind
            // it rather than as three controls beside it.
            <Button
              disabled={busy || !view || recordsUnknown}
              onClick={doInstall}
            >
              {INSTALL_ACTION}
            </Button>
          ) : null
        }
      />
      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className={cn(PAGE_BODY, "pt-0")}>
          <div
            className={cn(
              WIDE_CONTENT_WIDTH,
              "grid gap-8 lg:grid-cols-[minmax(0,1fr)_20rem]",
            )}
          >
            <div className="min-w-0 space-y-8">
              {shownError ? (
                <p className="text-sm text-critical" role="alert">
                  {shownError}
                </p>
              ) : null}
              {recordsUnknown && scope ? (
                <RecordsUnreadableNote scope={scope} />
              ) : null}
              {/* The reading comes before the package's own words about
                  itself: the header already says what this is, and this is
                  the page somebody installs from. */}
              {view ? (
                <SafetyPanel result={view.safety} notes={view.safety.notes} />
              ) : null}
              {view?.preview.readme ? (
                <section>
                  <MarkdownView source={view.preview.readme} />
                </section>
              ) : view && !error ? (
                <p className="text-sm text-muted-foreground">
                  {NO_README_NOTE}
                </p>
              ) : null}
              {/* The same tree and preview the installed package page's
                  Files tab draws, so what a package is made of reads the
                  same before and after it lands. */}
              {view && view.preview.files.length > 0 ? (
                <section className="space-y-3">
                  <SectionHeading>{FILES_TAB}</SectionHeading>
                  <FileBrowser
                    entries={fileEntries}
                    selected={selectedFile}
                    onSelect={selectFile}
                    label={FILE_TREE_LABEL}
                  >
                    {selectedFile ? (
                      <CatalogFilePreview
                        catalog={catalog}
                        kind={kind}
                        name={name}
                        path={selectedFile}
                      />
                    ) : (
                      <p className="text-sm text-muted-foreground">
                        {PICK_A_FILE_NOTE}
                      </p>
                    )}
                  </FileBrowser>
                </section>
              ) : null}
            </div>
            <AvailableAside
              marketplace={marketplace}
              repo={repo}
              view={view}
              onOpenMarketplace={() => goToMarketplace(catalog)}
              onOpenBundle={(bundle) => goToBundle({ catalog, bundle })}
            />
          </div>
        </div>
      </div>
    </div>
  );
}
