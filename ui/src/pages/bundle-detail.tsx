import { useCallback, useState } from "react";
import type { InstallItem, InstallState, ItemKind } from "@/bindings";
import {
  BundleMemberLine,
  memberKey,
} from "@/components/marketplaces/bundle-member-row";
import { RecordsUnreadableNote } from "@/components/marketplaces/packages-trouble";
import { RepoAction } from "@/components/marketplaces/repo-action";
import {
  useCachedRead,
  useCatalog,
} from "@/components/marketplaces/use-catalog";
import { PageHeader } from "@/components/page-header";
import { Button } from "@/components/ui/button";
import {
  INSTALL_ACTION,
  justThisLabel,
  packageCount,
  selectedLabel,
  wholeSetLabel,
  wholeSetWhat,
} from "@/lib/copy-install";
import { offersInstall } from "@/lib/install-state";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { type InstallSubject, useInstallFlow } from "@/stores/install-flow";
import { bundleKey, useMarketplacesStore } from "@/stores/marketplaces";
import { type BundleRef, useNavStore } from "@/stores/nav";

/** One curated set: install the whole thing as a set that keeps itself
 * whole, or pick members to install as your own choices. Both go through
 * the normal preview, safety score in view and never a gate. From a
 * repository nobody subscribes to yet, the members are listed and
 * Subscribe is the one action. */
export function BundleDetailPage() {
  const bundleRef = useNavStore((s) => s.bundleRef);
  if (!bundleRef) return null;
  return <BundleDetail bundleRef={bundleRef} />;
}

function BundleDetail({ bundleRef }: { bundleRef: BundleRef }) {
  const { bundle } = bundleRef;
  const {
    catalog,
    summary,
    display,
    error: reachError,
    ready,
  } = useCatalog(bundleRef.catalog);
  const bundles = useMarketplacesStore((s) => s.bundles);
  const readErrors = useMarketplacesStore((s) => s.readErrors);
  const loadBundle = useMarketplacesStore((s) => s.loadBundle);
  const busy = useMarketplacesStore((s) => s.busy);
  const openInstall = useInstallFlow((s) => s.open);
  const [selected, setSelected] = useState<Set<string>>(new Set());

  const subscribed = catalog.by === "subscription" ? catalog : null;
  const scope = subscribed?.scope ?? null;

  // Read for the place this set is offered in. Where an install lands is
  // the guided flow's own question, asked after this page has said what
  // the set holds — so the member states here answer for the marketplace's
  // own place rather than for a destination nobody has picked yet.
  const key = bundleKey(catalog, bundle, null);
  const detail = bundles[key];
  const readError = reachError ?? readErrors[key];
  const readBundle = useCallback(
    () => loadBundle(catalog, bundle, null),
    [loadBundle, catalog, bundle],
  );
  useCachedRead(detail !== undefined, !!readErrors[key], ready, readBundle);

  // A tick is an answer about a member that could be installed. A landed
  // install drops every set cache and the read comes back with that member
  // marked installed, so the tick is read against what the member is NOW
  // rather than stored and left standing: kept, it would leave a disabled
  // box checked and offer an already-installed member to the next Install.
  const isTicked = (member: {
    kind: ItemKind;
    name: string;
    state: InstallState;
  }) =>
    selected.has(memberKey(member.kind, member.name)) &&
    offersInstall(member.state);

  const toggleMember = (kind: string, name: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      const id = memberKey(kind, name);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  // Nothing re-reads the member list by hand: a successful install drops
  // every set cache, which empties this slot, and the read above watches
  // presence — so a row flips to Installed the moment it is, asked once.
  const group = (items: InstallItem[], asSet: boolean) => ({
    source: subscribed?.source ?? "",
    browsing: scope ?? { scope: "global" as const },
    items,
    bundle: asSet ? bundle : null,
  });
  /** The set as a whole, and the members ticked — the two answers this
   *  page has to the what question, offered together so the reader picks
   *  between them inside the one flow rather than between two buttons of
   *  equal weight in two different corners of the page. */
  const subjects = (): InstallSubject[] => {
    if (!detail) return [];
    const ticked = detail.members.filter(isTicked);
    const whole: InstallSubject = {
      id: "whole",
      label: wholeSetLabel(bundle),
      what: wholeSetWhat(bundle),
      count: detail.members.length,
      groups: [group([], true)],
      // A set install declares every kind whatever the set happens to
      // hold, which is the answer naming no kind gets.
      kinds: [],
    };
    if (ticked.length === 0) return [whole];
    return [
      whole,
      {
        id: "ticked",
        label: selectedLabel(ticked.length),
        what: packageCount(ticked.length),
        count: ticked.length,
        groups: [
          group(
            ticked.map((m) => ({ kind: m.kind, name: m.name })),
            false,
          ),
        ],
        kinds: [...new Set(ticked.map((m) => m.kind))],
      },
    ];
  };
  const startInstall = (only?: { kind: ItemKind; name: string }) => {
    if (!subscribed || !detail) return;
    if (only) {
      openInstall({
        subjects: [
          {
            id: `${only.kind}:${only.name}`,
            label: justThisLabel(only.name),
            what: only.name,
            count: 1,
            groups: [group([{ kind: only.kind, name: only.name }], false)],
            kinds: [only.kind],
          },
        ],
      });
      return;
    }
    const answers = subjects();
    if (answers.length > 0) openInstall({ subjects: answers });
  };
  // The lock of the place this set is offered in could not be read, so no
  // member's standing is known and every per-member box is already off.
  // Install asks about the set rather than a member, so it reads that
  // place's own answer off the payload: a member the catalog does not offer
  // has the same state with or without a lock, so no scan of the rows
  // could tell.
  const recordsUnknown = detail?.recordsUnreadable ?? false;

  return (
    <div className="flex h-full flex-col">
      <PageHeader
        title={bundle}
        subtitle={
          detail ? (
            <>
              {detail.description ? <p>{detail.description}</p> : null}
              <p className="mt-1 text-xs">
                {[detail.version ? `v${detail.version}` : null, display.name]
                  .filter(Boolean)
                  .join(" · ")}
              </p>
            </>
          ) : null
        }
        action={
          subscribed ? (
            // One button, whatever is ticked: the whole set and the ticked
            // members are two answers to the flow's own what question, not
            // two buttons in two corners of the page.
            <Button
              disabled={busy || !detail || recordsUnknown}
              onClick={() => startInstall()}
            >
              {INSTALL_ACTION}
            </Button>
          ) : catalog.by === "repo" ? (
            <RepoAction
              repo={catalog.repo}
              summary={summary}
              subscribeLabel="Subscribe to install"
            />
          ) : null
        }
      />
      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className={cn(PAGE_BODY, "pt-0")}>
          <div className={CONTENT_WIDTH}>
            {!detail && readError ? (
              <p
                className="py-16 text-center text-sm text-critical"
                role="alert"
              >
                This set can't be read right now — {readError}
              </p>
            ) : !detail ? (
              <p className="py-16 text-center text-sm text-muted-foreground">
                Reading the set…
              </p>
            ) : (
              <>
                {recordsUnknown && scope ? (
                  <div className="mb-3">
                    <RecordsUnreadableNote scope={scope} />
                  </div>
                ) : null}
                <div className="divide-y rounded-lg border">
                  {detail.members.map((member) => (
                    <BundleMemberLine
                      key={memberKey(member.kind, member.name)}
                      member={member}
                      selectable={subscribed !== null}
                      selected={isTicked(member)}
                      busy={busy}
                      onToggle={() => toggleMember(member.kind, member.name)}
                      onRestore={() =>
                        startInstall({ kind: member.kind, name: member.name })
                      }
                    />
                  ))}
                </div>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
