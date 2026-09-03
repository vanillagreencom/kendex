import { useCallback, useState } from "react";
import type { ItemKind, Scope } from "@/bindings";
import { BundleInstallBar } from "@/components/marketplaces/bundle-install-bar";
import {
  BundleMemberLine,
  memberKey,
} from "@/components/marketplaces/bundle-member-row";
import type { Choice } from "@/components/marketplaces/harness-select";
import { RecordsUnreadableNote } from "@/components/marketplaces/packages-trouble";
import { RepoAction } from "@/components/marketplaces/repo-action";
import {
  useCachedRead,
  useCatalog,
} from "@/components/marketplaces/use-catalog";
import { PageHeader } from "@/components/page-header";
import { Button } from "@/components/ui/button";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { sameScope } from "@/lib/scope";
import { cn } from "@/lib/utils";
import {
  bundleKey,
  catalogLabel,
  useMarketplacesStore,
} from "@/stores/marketplaces";
import { type BundleRef, useNavStore } from "@/stores/nav";

/** One curated set: install the whole thing as a set that keeps itself
 * whole, or pick members to install as your own choices. Both go through
 * the normal preview, safety score in view and never a gate. From a
 * repository nobody subscribes to yet, the members are listed and
 * Subscribe is the one action. */
/** Nothing answered yet. A destination decides which tools can take the
 *  install and which extras it brings, so both reset with it. */
const NO_CHOICE: Choice = { harnesses: null, method: null, optional: [] };

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
    error: reachError,
    ready,
  } = useCatalog(bundleRef.catalog);
  const bundles = useMarketplacesStore((s) => s.bundles);
  const readErrors = useMarketplacesStore((s) => s.readErrors);
  const loadBundle = useMarketplacesStore((s) => s.loadBundle);
  const install = useMarketplacesStore((s) => s.install);
  const busy = useMarketplacesStore((s) => s.busy);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [destination, setDestination] = useState<Scope | null>(null);
  const [choice, setChoice] = useState<Choice>(NO_CHOICE);

  const subscribed = catalog.by === "subscription" ? catalog : null;
  const scope = subscribed?.scope ?? null;
  const target = destination ?? scope;
  // "The same place" has one answer, and it is not object identity: the
  // picker hands back a freshly built Scope, so picking the place already
  // being browsed would otherwise read as a redirect and ask again under a
  // second cache key.
  const redirected =
    target && scope && !sameScope(target, scope) ? target : null;

  // The destination is part of the read, not a filter over it: every
  // member's state and the set's own record standing are facts about the
  // scope the install lands in, so each place has a slot of its own and
  // choosing one already read is served from it.
  const key = bundleKey(catalog, bundle, redirected);
  const detail = bundles[key];
  const readError = reachError ?? readErrors[key];
  const readBundle = useCallback(
    () => loadBundle(catalog, bundle, redirected),
    [loadBundle, catalog, bundle, redirected],
  );
  useCachedRead(detail !== undefined, !!readErrors[key], ready, readBundle);

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
  const installItems = (items: { kind: ItemKind; name: string }[]) => {
    if (!subscribed) return;
    void install({
      scope: subscribed.scope,
      source: subscribed.source,
      items: items.map((m) => ({ kind: m.kind, name: m.name })),
      bundle: items.length === 0 ? bundle : null,
      destination: redirected,
      delivery: choice,
    }).then((ok) => {
      if (ok) setSelected(new Set());
    });
  };
  const installSelected = () => {
    if (!detail) return;
    const items = detail.members.filter((m) =>
      selected.has(memberKey(m.kind, m.name)),
    );
    if (items.length > 0) installItems(items);
  };
  // The lock of the place this install would land in could not be read, so
  // no member's standing is known and every per-member box is already off.
  // "Install all" asks about the set rather than a member, so it reads that
  // place's own answer off the payload: a member the catalog dropped says
  // "no longer offered" with or without a lock, so no scan of the rows
  // could tell. Landing place, not browsed one — the engine mutates where
  // the install goes.
  const recordsUnknown = detail?.recordsUnreadable ?? false;
  // Which tools the picker may offer follows what is actually ticked; with
  // nothing ticked the set is every kind, which is what the whole bundle
  // would carry.
  const selectedKinds = [
    ...new Set(
      (detail?.members ?? [])
        .filter((m) => selected.has(memberKey(m.kind, m.name)))
        .map((m) => m.kind),
    ),
  ];

  return (
    <div className="flex h-full flex-col">
      <PageHeader
        title={bundle}
        subtitle={
          detail ? (
            <>
              {detail.description ? <p>{detail.description}</p> : null}
              <p className="mt-1 text-xs">
                {[
                  detail.version ? `v${detail.version}` : null,
                  catalogLabel(catalog),
                ]
                  .filter(Boolean)
                  .join(" · ")}
              </p>
            </>
          ) : null
        }
        action={
          subscribed ? (
            <Button
              disabled={busy || !detail || recordsUnknown}
              onClick={() => installItems([])}
            >
              Install all
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
            {subscribed && scope && target ? (
              <BundleInstallBar
                browsing={scope}
                target={target}
                kinds={selectedKinds}
                choice={choice}
                picked={selected.size}
                busy={busy}
                onPlace={(next) => {
                  // Which tools can take this is a fact about the
                  // destination, so a choice made against another one is not
                  // an answer here. Nor is a ticked member: the box was
                  // ticked against the state the place before it answered,
                  // and the new place may already hold that member or refuse
                  // to say.
                  setChoice(NO_CHOICE);
                  setSelected(new Set());
                  setDestination(next);
                }}
                onChoice={setChoice}
                onInstall={installSelected}
              />
            ) : null}
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
                {recordsUnknown && target ? (
                  <div className="mb-3">
                    <RecordsUnreadableNote scope={target} />
                  </div>
                ) : null}
                <div className="divide-y rounded-lg border">
                  {detail.members.map((member) => (
                    <BundleMemberLine
                      key={memberKey(member.kind, member.name)}
                      member={member}
                      selectable={subscribed !== null}
                      selected={selected.has(
                        memberKey(member.kind, member.name),
                      )}
                      busy={busy}
                      onToggle={() => toggleMember(member.kind, member.name)}
                      onRestore={() => installItems([member])}
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
