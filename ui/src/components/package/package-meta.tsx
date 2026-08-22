import { type ReactNode, useEffect } from "react";
import type {
  HarnessId,
  ObservedItem,
  PackageMeta_Serialize,
} from "@/bindings";
import { HarnessBadge } from "@/components/harness-badge";
import { SectionHeading } from "@/components/section";
import { StatusLine } from "@/components/status-note";
import { TagBadges } from "@/components/tag-badge";
import { Badge } from "@/components/ui/badge";
import {
  ORIGIN_UNCONFIRMED,
  ORIGIN_UNREAD,
  originUnconfirmedTitle,
  TAGS_ROW_LABEL,
} from "@/lib/copy";
import type { ItemGroup } from "@/lib/derive";
import { kindLabel, scopeName } from "@/lib/labels";
import { relativeTime } from "@/lib/relative-time";
import { versionLabel } from "@/lib/versions";
import { subscription } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import {
  indexOrigins,
  originFor,
  originTitle,
  useProvenanceStore,
} from "@/stores/provenance";

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex gap-3 text-sm">
      <dt className="w-20 shrink-0 text-muted-foreground">{label}</dt>
      <dd className="min-w-0 flex-1">{children}</dd>
    </div>
  );
}

/** The origin the last successful read gave, when the read after it failed.
 *  The store keeps its rows so the row is not blanked, and this is what
 *  separates the answer it kept from one it just confirmed. */
function LastKnown({ why }: { why: string }) {
  return (
    <span
      className="ml-1.5 text-muted-foreground text-xs"
      title={originUnconfirmedTitle(why)}
    >
      {ORIGIN_UNCONFIRMED}
    </span>
  );
}

/** The Details block of the package page: what the scan observed plus the
 *  provenance the manifest and catalog record. Rows render only when they
 *  have something to say. */
export function PackageMetaBlock({
  group,
  primary,
  meta,
}: {
  group: ItemGroup;
  primary: ObservedItem;
  meta: PackageMeta_Serialize | null;
}) {
  const provenance = useProvenanceStore((s) => s.rows);
  const loadedProvenance = useProvenanceStore((s) => s.loaded);
  const loadProvenance = useProvenanceStore((s) => s.load);
  const originError = useProvenanceStore((s) => s.error);
  const goToMarketplace = useNavStore((s) => s.goToMarketplace);
  // A package page can be the first thing opened after launch; the join
  // may not have been read yet, and this line is its only reader here.
  useEffect(() => {
    if (!loadedProvenance) void loadProvenance();
  }, [loadedProvenance, loadProvenance]);
  // This place's origin, not any place's: the same package can come from a
  // marketplace here and be your own copy in the next project, and the link
  // below navigates to whichever this line names.
  const origin = originFor(indexOrigins(provenance), group.kind, group.name, [
    primary.scope,
  ]);
  return (
    <div className="space-y-2.5">
      <SectionHeading>Details</SectionHeading>
      <dl className="space-y-2">
        <Row label="Type">{kindLabel(group.kind)}</Row>
        {group.tags.length > 0 ? (
          <Row label={TAGS_ROW_LABEL}>
            <TagBadges tags={group.tags} />
          </Row>
        ) : null}
        <Row label="Harnesses">
          <span className="flex flex-wrap gap-1">
            {group.harnesses.map((h) => (
              <HarnessBadge key={h} harness={h as HarnessId} />
            ))}
            {group.shared ? (
              <Badge variant="secondary">Shared files</Badge>
            ) : null}
          </span>
        </Row>
        <Row label="Scope">{scopeName(primary.scope)}</Row>
        {origin?.origin === "marketplace" ? (
          <Row label="From">
            <button
              type="button"
              className="underline underline-offset-2 hover:text-foreground"
              title={originTitle(origin)}
              onClick={() =>
                goToMarketplace(subscription(primary.scope, origin.source))
              }
            >
              {origin.source}
            </button>
            {originError ? <LastKnown why={originError} /> : null}
          </Row>
        ) : origin?.origin === "own" ? (
          <Row label="From">
            <span title={originTitle(origin)}>Your own</span>
            {originError ? <LastKnown why={originError} /> : null}
          </Row>
        ) : originError ? (
          <Row label="From">
            <span className="text-muted-foreground" title={originError}>
              {ORIGIN_UNREAD}
            </span>
          </Row>
        ) : null}
        {meta?.current ? (
          <Row label="Version">{versionLabel(meta.current)}</Row>
        ) : null}
        {meta?.repo ? (
          <Row label="Source">
            <span className="break-all">{meta.repo}</span>
          </Row>
        ) : primary.origin === "local" ? (
          <Row label="Source">Managed from this machine</Row>
        ) : null}
        {meta?.catalog?.author ? (
          <Row label="Author">{meta.catalog.author}</Row>
        ) : null}
        {meta?.catalog?.license ? (
          <Row label="License">{meta.catalog.license}</Row>
        ) : null}
        <Row label="Path">
          <span className="break-all font-mono text-xs">{primary.path}</span>
        </Row>
        {group.modifiedAt != null ? (
          <Row label="Updated">
            {relativeTime(group.modifiedAt * 1000, Date.now())}
          </Row>
        ) : null}
      </dl>
      {primary.fileState.state === "symlink" && primary.fileState.broken ? (
        <StatusLine tone="critical">The link is broken.</StatusLine>
      ) : null}
    </div>
  );
}
