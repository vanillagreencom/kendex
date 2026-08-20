// Subscribing a scope to a catalog: a repository, a path, or a skills.sh
// reference that leads with one package. Nothing is fetched — the mock
// harness has no network — so the new row carries no content yet.
import type { Scope, SubscribeOutcome } from "@/bindings";
import { packagesKey } from "./fixture-marketplaces";
import { marketplaceRow } from "./mock-catalog";
import { type Handler, label, same, store } from "./mock-state";

const referenceLeaf = (reference: string): string => {
  const trimmed = reference.replace(/\/+$/, "").replace(/\.git$/, "");
  const leaf = trimmed.split(/[/:]/).at(-1);
  return leaf && leaf.length > 0 ? leaf.replace(/@.*$/, "") : "source";
};

export const subscribeHandlers: Record<string, Handler> = {
  marketplace_subscribe: ({
    scope,
    reference,
    name,
  }: {
    scope: Scope;
    reference: string;
    name: string | null;
  }): SubscribeOutcome | Promise<never> => {
    const isPath = reference.startsWith("/") || reference.startsWith(".");
    const [base, rev] = isPath
      ? [reference, null]
      : [
          reference.replace(/@[^/]*$/, ""),
          reference.match(/@([^/]+)$/)?.[1] ?? null,
        ];
    const alias = name ?? referenceLeaf(reference);
    const existing = marketplaceRow(scope, alias);
    if (existing && (existing.repo ?? existing.path) !== base) {
      return Promise.reject(
        `'${alias}' already points at ${existing.repo ?? existing.path} — remove that subscription first, or pick another name`,
      );
    }
    const taken = store.state.marketplaces.find(
      (row) =>
        same(row.scope, scope) && row.repo === base && row.name !== alias,
    );
    if (taken) {
      return Promise.reject(
        `${base} is already subscribed here as '${taken.name}'`,
      );
    }
    if (!existing) {
      store.state.marketplaces.push({
        scope,
        name: alias,
        repo: isPath ? null : base,
        repoKey: isPath ? null : base.toLowerCase(),
        path: isPath ? base : null,
        rev,
        commit: null,
        enabled: true,
        counts: null,
        meta: null,
        mode: null,
      });
      // A listed repository's offer is already in the store: the new
      // subscription reads it at once, so a page that was browsing the
      // repository carries on as the subscription with Install available.
      const browsed = store.state.repoPackages[base];
      if (browsed) {
        store.state.marketplacePackages[packagesKey(scope, alias)] =
          structuredClone(browsed);
      }
      store.state.sources.push({
        scope,
        name: alias,
        reference: base,
        isRemote: !isPath,
        enabled: true,
        head: null,
        declaredItems: [],
      });
    }
    return {
      name: alias,
      reference: base,
      rev,
      lead: reference.includes("skills.sh") ? referenceLeaf(reference) : null,
      notes: [
        `Subscribes ${label(scope)} to '${alias}' (${rev ? `${base} @ ${rev}` : base})`,
        "not fetched yet (the mock harness has no network)",
      ],
    };
  },
};
