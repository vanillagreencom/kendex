import { useEffect, useRef, useState } from "react";
import { commands, type PackageView, type Scope } from "@/bindings";
import { MarkdownView } from "@/components/markdown-view";
import { AvailableAside } from "@/components/marketplaces/available-aside";
import { CatalogFilePreview } from "@/components/marketplaces/catalog-file-preview";
import { DestinationSelect } from "@/components/marketplaces/destination-select";
import { RepoAction } from "@/components/marketplaces/repo-action";
import { useCatalog } from "@/components/marketplaces/use-catalog";
import { PageHeader } from "@/components/page-header";
import { FindingLine } from "@/components/safety-findings";
import { TagBadges } from "@/components/tag-badge";
import { Button } from "@/components/ui/button";
import { publisherSettledNote } from "@/lib/copy-safety";
import { kindIcon } from "@/lib/kind-icon";
import { kindLabel, packageDisplayName } from "@/lib/labels";
import { latestOnly } from "@/lib/latest";
import { PAGE_BODY, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { cn } from "@/lib/utils";
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
    error: reachError,
    ready,
  } = useCatalog(availableRef.catalog);
  const goToPackage = useNavStore((s) => s.goToPackage);
  const rows = useMarketplacesStore((s) => s.rows);
  const install = useMarketplacesStore((s) => s.install);
  const busy = useMarketplacesStore((s) => s.busy);
  const [view, setView] = useState<PackageView | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [destination, setDestination] = useState<Scope | null>(null);

  const [selectedFile, setSelectedFile] = useState<string | null>(null);
  // The address can change under an in-flight read — a repository page
  // carrying on as the subscription it just gained — and the older answer
  // must not land on top of the newer one.
  const latest = useRef(latestOnly());

  useEffect(() => {
    if (!ready) return;
    setView(null);
    setError(null);
    setSelectedFile(null);
    void latest
      .current(commands.marketplacePackagePreview(catalog, kind, name))
      .then((r) => {
        if (!r) return;
        if (r.status === "ok") setView(r.data);
        else setError(r.error);
      });
  }, [catalog, ready, kind, name]);

  const Icon = kindIcon(kind);
  const scope = catalog.by === "subscription" ? catalog.scope : null;
  const target = destination ?? scope;
  // Matched by scope and name both — two scopes can subscribe the same
  // alias to different repositories.
  const row =
    catalog.by === "subscription"
      ? rows.find(
          (r) =>
            r.name === catalog.source &&
            catalogKey({
              by: "subscription",
              scope: r.scope,
              source: r.name,
            }) === catalogKey(catalog),
        )
      : undefined;
  const repo = row?.repo ?? row?.path ?? summary?.provenance ?? null;
  const shownError = reachError ?? error;

  const doInstall = () => {
    if (catalog.by !== "subscription" || !target) return;
    const { scope, source } = catalog;
    void install({
      scope,
      source,
      items: [{ kind, name }],
      destination: target !== scope ? target : null,
    }).then((ok) => {
      // Installed, the same page carries on in its installed mode — the
      // address gains the scope it landed in.
      if (ok) goToPackage({ kind, name, scope: target });
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
            {view?.preview.description ? (
              <p>{view.preview.description}</p>
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
          ) : scope && target ? (
            <>
              <DestinationSelect
                browsing={scope}
                value={target}
                onChange={setDestination}
              />
              <Button disabled={busy || !view} onClick={doInstall}>
                {busy ? "Installing…" : "Install"}
              </Button>
            </>
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
              {view && selectedFile ? (
                <section>
                  <CatalogFilePreview
                    catalog={catalog}
                    kind={kind}
                    name={name}
                    path={selectedFile}
                  />
                </section>
              ) : view?.preview.readme ? (
                <section>
                  <MarkdownView source={view.preview.readme} />
                </section>
              ) : view && !error ? (
                <p className="text-sm text-muted-foreground">
                  This package carries no README.
                </p>
              ) : null}
              {view && view.safety.findings.length > 0 ? (
                <section>
                  <h3 className="mb-3 text-sm font-semibold">
                    Before you install
                  </h3>
                  <div className="space-y-3">
                    {view.safety.findings.map((finding, index) => {
                      const settled = view.safety.settled[index];
                      // A finding the publisher already ruled on is shown
                      // like any other and says whose call it was: it does
                      // not count toward the score here, exactly as it will
                      // not count when this installs.
                      return settled ? (
                        <FindingLine
                          key={`${finding.location}:${finding.message}`}
                          finding={finding}
                          settledBy={publisherSettledNote(
                            view.safety.publisher ?? "The publisher",
                            settled.reason,
                            null,
                          )}
                        />
                      ) : (
                        <FindingLine
                          key={`${finding.location}:${finding.message}`}
                          finding={finding}
                        />
                      );
                    })}
                  </div>
                </section>
              ) : null}
            </div>
            <AvailableAside
              catalog={catalog}
              repo={repo}
              view={view}
              selectedFile={selectedFile}
              onSelectFile={setSelectedFile}
            />
          </div>
        </div>
      </div>
    </div>
  );
}
