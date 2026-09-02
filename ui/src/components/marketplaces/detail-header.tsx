import { MoreHorizontal, RefreshCw, Star } from "lucide-react";
import { Fragment, type ReactNode, useState } from "react";
import type { Catalog, CatalogSummary, MarketplaceRow } from "@/bindings";
import { ExternalLink } from "@/components/external-link";
import { RepoAction } from "@/components/marketplaces/repo-action";
import { UnsubscribeDialog } from "@/components/marketplaces/unsubscribe-dialog";
import { PageHeader } from "@/components/page-header";
import { StatusNote } from "@/components/status-note";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  FEATURED_MARKER,
  MARKETPLACES_UNCONFIRMED_TITLE,
} from "@/lib/copy-marketplaces";
import { shortRevision } from "@/lib/labels";
import { PAGE_BODY, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useCommunityStore } from "@/stores/community";
import { useMarketplacesStore } from "@/stores/marketplaces";

/** The marketplace page's header for either kind of catalog: a
 * subscription's refresh and unsubscribe, or a repository's one Subscribe
 * button. The words come from the catalog itself where it has been read,
 * and from the directory's listing until then. Whether a place offers this
 * marketplace's packages is the Projects section's answer, not a switch
 * up here with no place named beside it. */
export function DetailHeader({
  requested,
  catalog,
  row,
  summary,
}: {
  /** What was opened — a repository keeps its listing's name and tags. */
  requested: Catalog;
  catalog: Catalog;
  row: MarketplaceRow | undefined;
  summary: CatalogSummary | null;
}) {
  const checkForUpdates = useMarketplacesStore((s) => s.checkForUpdates);
  const busy = useMarketplacesStore((s) => s.busy);
  // A subscription row selected from rows a failed read left behind may
  // not be the subscription as it stands now, and the page says so below
  // the header.
  const read = useMarketplacesStore((s) => s.read);
  const load = useMarketplacesStore((s) => s.load);
  const stale = catalog.by === "subscription" && read.status === "failed";
  const listing = useCommunityStore((s) =>
    requested.by === "repo"
      ? s.directory?.rows.find((r) => r.repo === requested.repo)
      : undefined,
  );
  const [unsubscribeOpen, setUnsubscribeOpen] = useState(false);

  const meta = row?.meta ?? summary?.meta ?? null;
  const title =
    catalog.by === "subscription"
      ? catalog.source
      : (listing?.name ?? meta?.name ?? catalog.repo.split("/").at(-1));
  const description = meta?.description ?? listing?.description ?? null;
  const commit = row?.commit ?? summary?.commit ?? null;
  // What the catalog came from, as text. A path source has a folder here.
  const provenance =
    row?.repo ?? row?.path ?? summary?.provenance ?? listing?.repo ?? null;
  // The canonical `owner/repo` a GitHub reference folds to, which is the
  // only thing a github.com URL may be built from. Every branch is a folded
  // key — never the raw `listing.repo`, which is whatever the community
  // index happened to hold: a full URL, a `.git` suffix, another host. The
  // fold answers null for those, and null is the answer that leaves the
  // provenance as plain text instead of a link that opens nothing.
  const repoKey = row?.repoKey ?? summary?.repoKey ?? listing?.repoKey ?? null;
  // One line, one separator. Each part is a node with its own name, and the
  // interleaving is spelled once, so nothing re-derives whether anything
  // precedes it and every gap is the same gap.
  const metaParts: { key: string; node: ReactNode }[] = [
    provenance
      ? {
          key: "provenance",
          node: repoKey ? (
            <ExternalLink url={`https://github.com/${repoKey}`}>
              {provenance}
            </ExternalLink>
          ) : (
            <span>{provenance}</span>
          ),
        }
      : null,
    meta?.homepage
      ? {
          key: "homepage",
          node: (
            <ExternalLink url={meta.homepage}>{meta.homepage}</ExternalLink>
          ),
        }
      : null,
    // Keyed by which field it is, never by the text: these are the
    // catalog's own strings, and two fields carrying the same one — an
    // author and a license naming the same party, say — would key two
    // siblings alike and let reconciliation keep or drop the wrong one.
    // Both still render; it is only the key that has to be distinct.
    commit
      ? { key: "commit", node: <span>{`@ ${shortRevision(commit)}`}</span> }
      : null,
    meta?.license
      ? { key: "license", node: <span>{meta.license}</span> }
      : null,
    meta?.author
      ? { key: "author", node: <span>{`by ${meta.author}`}</span> }
      : null,
  ].filter((part) => part !== null);
  const tags = [...new Set([...(meta?.tags ?? []), ...(listing?.tags ?? [])])];

  let action: ReactNode;
  if (catalog.by === "subscription") {
    const { scope, source } = catalog;
    action = (
      <>
        <Button
          size="sm"
          variant="outline"
          disabled={busy}
          onClick={() => void checkForUpdates()}
        >
          <RefreshCw className={cn("size-4", busy && "animate-spin")} />
          Check for updates
        </Button>
        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <Button size="icon-xs" variant="quiet" aria-label="More actions">
                <MoreHorizontal className="size-4" />
              </Button>
            }
          />
          <DropdownMenuContent align="end">
            <DropdownMenuItem
              className="text-critical"
              onClick={() => setUnsubscribeOpen(true)}
            >
              Unsubscribe…
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        <UnsubscribeDialog
          open={unsubscribeOpen}
          onOpenChange={setUnsubscribeOpen}
          scope={scope}
          source={source}
        />
      </>
    );
  } else {
    action = (
      <RepoAction
        repo={catalog.repo}
        summary={summary}
        subscribeLabel="Subscribe"
      />
    );
  }

  return (
    <>
      <PageHeader
        wide
        title={
          <span className="flex items-center gap-2.5">
            {title}
            {listing?.featured ? (
              <Badge variant="warning" className="gap-1">
                <Star className="size-3" /> {FEATURED_MARKER}
              </Badge>
            ) : null}
            {/* The switch moved to Projects, so the page has to say by
                itself that the place it opened as is not offering these
                packages — otherwise the list reads as installable. */}
            {row && !row.enabled ? (
              <Badge variant="outline">Switched off here</Badge>
            ) : null}
          </span>
        }
        subtitle={
          <>
            {description ? <p>{description}</p> : null}
            {metaParts.length > 0 ? (
              <p className="mt-1 flex flex-wrap items-center gap-x-1.5 font-mono text-xs">
                {metaParts.map((part, index) => (
                  <Fragment key={part.key}>
                    {index > 0 ? <span aria-hidden>·</span> : null}
                    {part.node}
                  </Fragment>
                ))}
              </p>
            ) : null}
            {tags.length > 0 ? (
              <span className="mt-2 flex flex-wrap gap-1.5">
                {tags.map((tag) => (
                  <Badge key={tag} variant="secondary">
                    {tag}
                  </Badge>
                ))}
              </span>
            ) : null}
          </>
        }
        action={action}
      />
      {stale ? (
        <div className={cn(PAGE_BODY, "pt-0")}>
          <div className={WIDE_CONTENT_WIDTH}>
            <StatusNote
              tone="warning"
              title={MARKETPLACES_UNCONFIRMED_TITLE}
              action={
                <Button size="sm" variant="outline" onClick={() => void load()}>
                  {TRY_AGAIN_LABEL}
                </Button>
              }
            >
              {read.error}
            </StatusNote>
          </div>
        </div>
      ) : null}
    </>
  );
}
