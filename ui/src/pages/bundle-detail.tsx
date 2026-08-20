import { useEffect, useState } from "react";
import type { ItemKind, Scope } from "@/bindings";
import {
  BundleMemberLine,
  memberKey,
} from "@/components/marketplaces/bundle-member-row";
import { DestinationSelect } from "@/components/marketplaces/destination-select";
import { SubscribeFromRepo } from "@/components/marketplaces/subscribe-from-repo";
import { useCatalog } from "@/components/marketplaces/use-catalog";
import { PageHeader } from "@/components/page-header";
import { Button } from "@/components/ui/button";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { cn } from "@/lib/utils";
import {
  catalogKey,
  catalogLabel,
  useMarketplacesStore,
} from "@/stores/marketplaces";
import { type BundleRef, useNavStore } from "@/stores/nav";

/** One curated set: install the whole thing as a set that keeps itself
 * whole, or pick members to install as your own choices. Both go through
 * the normal preview and safety gate. From a repository nobody subscribes
 * to yet, the members are listed and Subscribe is the one action. */
export function BundleDetailPage() {
  const bundleRef = useNavStore((s) => s.bundleRef);
  if (!bundleRef) return null;
  return <BundleDetail bundleRef={bundleRef} />;
}

function BundleDetail({ bundleRef }: { bundleRef: BundleRef }) {
  const { bundle } = bundleRef;
  const { catalog, error: reachError, ready } = useCatalog(bundleRef.catalog);
  const bundles = useMarketplacesStore((s) => s.bundles);
  const readErrors = useMarketplacesStore((s) => s.readErrors);
  const loadBundle = useMarketplacesStore((s) => s.loadBundle);
  const install = useMarketplacesStore((s) => s.install);
  const busy = useMarketplacesStore((s) => s.busy);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [destination, setDestination] = useState<Scope | null>(null);

  useEffect(() => {
    if (ready) void loadBundle(catalog, bundle);
  }, [catalog, ready, bundle, loadBundle]);

  const key = `${catalogKey(catalog)}::${bundle}`;
  const detail = bundles[key];
  const readError = reachError ?? readErrors[key];
  const subscribed = catalog.by === "subscription" ? catalog : null;
  const scope = subscribed?.scope ?? null;
  const target = destination ?? scope;
  const redirected = target && scope && target !== scope ? target : null;

  const toggleMember = (kind: string, name: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      const id = memberKey(kind, name);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  // The member list re-reads after any install, so a row flips to
  // Installed the moment it is.
  const reload = () => loadBundle(catalog, bundle);
  const installItems = (items: { kind: ItemKind; name: string }[]) => {
    if (!subscribed) return;
    void install({
      scope: subscribed.scope,
      source: subscribed.source,
      items: items.map((m) => ({ kind: m.kind, name: m.name })),
      bundle: items.length === 0 ? bundle : null,
      destination: redirected,
    }).then((ok) => {
      if (ok) {
        setSelected(new Set());
        void reload();
      }
    });
  };
  const installSelected = () => {
    if (!detail) return;
    const items = detail.members.filter((m) =>
      selected.has(memberKey(m.kind, m.name)),
    );
    if (items.length > 0) installItems(items);
  };

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
            <Button disabled={busy || !detail} onClick={() => installItems([])}>
              Install all
            </Button>
          ) : catalog.by === "repo" ? (
            <SubscribeFromRepo
              repo={catalog.repo}
              label="Subscribe to install"
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
                {subscribed && scope && target ? (
                  <div className="mt-4 flex items-center justify-end gap-2">
                    <DestinationSelect
                      browsing={scope}
                      value={target}
                      onChange={setDestination}
                    />
                    <Button
                      variant="outline"
                      disabled={busy || selected.size === 0}
                      onClick={installSelected}
                    >
                      Install {selected.size} selected
                    </Button>
                  </div>
                ) : null}
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
