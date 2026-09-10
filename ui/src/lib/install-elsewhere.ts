// Installing a package that is already installed somewhere into a project
// that lacks it.
//
// The package page knows what the package is and where its copies came
// from; it does not browse a marketplace. So the ask handed to the guided
// install is built from what the page already has — the subscription each
// copy records, resolved against the subscription list — and the where
// question stays inside that flow, where it is asked once for the whole
// app.
import type { ItemKind, MarketplaceRow, ProvenanceRow } from "@/bindings";
import type { InstallSubject } from "@/stores/install-flow";

/** The marketplaces this package's installed copies came from, in a stable
 *  order. A package can be installed from a different source in each
 *  place, and none of them need be the same subscription. */
const sourcesOf = (
  provenance: ProvenanceRow[],
  kind: ItemKind,
  name: string,
): string[] =>
  [
    ...new Set(
      provenance.flatMap((row) =>
        row.kind === kind &&
        row.name === name &&
        row.origin.origin === "marketplace"
          ? [row.origin.source]
          : [],
      ),
    ),
  ].sort();

/** The ask that installs this package into a project the reader picks, or
 *  null where kendex cannot offer one.
 *
 *  Null in two cases, and both are states rather than failures. A package
 *  nobody installed from a marketplace — the reader's own, adopted or
 *  forked — has no source to install from again. And a source declared
 *  only inside a project can be installed only where it is declared:
 *  `install-flow.ts`'s own rule is that a redirect into a chosen project
 *  needs a globally declared subscription, so offering the button over
 *  anything else would open a dialog whose install the engine refuses.
 *
 *  The first source in order rather than every one of them: the package is
 *  one thing to the reader, and a choice between marketplaces that carry
 *  the same package is a question about provenance nobody asked. */
export function installElsewhere(
  kind: ItemKind,
  name: string,
  shown: string,
  provenance: ProvenanceRow[],
  subscriptions: MarketplaceRow[],
): InstallSubject | null {
  const global = new Set(
    subscriptions
      .filter((row) => row.scope.scope === "global")
      .map((row) => row.name),
  );
  const source = sourcesOf(provenance, kind, name).find((one) =>
    global.has(one),
  );
  if (source === undefined) return null;
  return {
    id: `${kind}:${name}`,
    label: shown,
    what: shown,
    count: 1,
    groups: [
      {
        source,
        browsing: { scope: "global" },
        items: [{ kind, name }],
        bundle: null,
      },
    ],
    kinds: [kind],
  };
}
