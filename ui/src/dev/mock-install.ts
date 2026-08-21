// Installing from a subscription: a bundle or loose items, optionally
// redirected into a project that gains the subscription on the way.
import type { InstallItem, ItemKind, Scope } from "@/bindings";
import { BUNDLE_SPECS } from "./fixture-catalog";
import { packagesKey } from "./fixture-marketplaces";
import { marketplaceRow, offeredHere } from "./mock-catalog";
import { type Handler, same, store } from "./mock-state";

export const installHandlers: Record<string, Handler> = {
  marketplace_install: ({
    scope,
    source,
    items,
    bundle,
    destination,
  }: {
    scope: Scope;
    source: string;
    items: InstallItem[];
    bundle: string | null;
    destination: Scope | null;
    hold: boolean;
  }) => {
    if (items.length === 0 && !bundle) {
      return Promise.reject("nothing selected to install");
    }
    const target = destination ?? scope;
    if (!same(target, scope)) {
      if (target.scope !== "project") {
        return Promise.reject(
          "an install can only be redirected into a project",
        );
      }
      if (scope.scope !== "global") {
        return Promise.reject(
          "only a personal subscription can install into a project",
        );
      }
      // §4.1: the destination project gains the personal subscription it
      // lacks, so the install can resolve there.
      const personal = marketplaceRow(scope, source);
      if (!personal) return Promise.reject(`unknown source '${source}'`);
      if (!marketplaceRow(target, source)) {
        store.state.marketplaces.push({
          ...structuredClone(personal),
          scope: target,
        });
        const offered =
          store.state.marketplacePackages[packagesKey(scope, source)] ?? [];
        store.state.marketplacePackages[packagesKey(target, source)] =
          structuredClone(offered).map((pkg) => ({
            ...pkg,
            state: "available",
          }));
      }
    }
    const offered = offeredHere({ by: "subscription", scope: target, source });
    if (offered instanceof Promise) return offered;
    const wanted: { kind: ItemKind; name: string }[] = [];
    const takeBundle = (name: string) => {
      const spec = BUNDLE_SPECS[source]?.[name];
      if (!spec) return false;
      wanted.push(...spec.members);
      return true;
    };
    if (bundle && !takeBundle(bundle)) {
      return Promise.reject(`no bundle named '${bundle}' in '${source}'`);
    }
    for (const item of items) {
      // A plugin is its registry's curated set, so it installs as one.
      if (item.kind === "plugin") {
        if (!takeBundle(item.name)) {
          return Promise.reject(`'${item.name}' is not offered by '${source}'`);
        }
        continue;
      }
      if (item.kind === "pi-extension") {
        return Promise.reject(
          `'${item.name}' installs with the bundle that carries it, never on its own`,
        );
      }
      wanted.push(item);
    }
    for (const want of wanted) {
      const pkg = offered.find(
        (p) => p.kind === want.kind && p.name === want.name,
      );
      if (!pkg) {
        return Promise.reject(`'${want.name}' is not offered by '${source}'`);
      }
      pkg.state = "installed";
    }
    return offered;
  },
};
