import { useEffect, useRef, useState } from "react";
import {
  commands,
  type ItemKind,
  type PackageMeta_Serialize,
  type Scope,
} from "@/bindings";
import {
  installedCommits,
  type PackagePlace,
  packagePlaces,
} from "@/lib/package-places";
import { scopeKey } from "@/lib/scope";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";

type Metas = Record<string, PackageMeta_Serialize | null>;

/** What one pass over a package's places came back with: each place's own
 *  record, and whether the ownership join landed. Held together so a card
 *  never draws on one without the other. */
interface Read {
  metas: Metas;
  /** The provenance read answered. False keeps every removal closed: the
   *  rows on hand may predate an install or a take-over. */
  joined: boolean;
}

/** Every place this package sits in, with its install date and its update
 *  standing.
 *
 *  The page's own read answers for the one place it names, and the install
 *  date lives only in each place's own record — so every place is read
 *  here rather than having one place's date stand in for the rest.
 *
 *  `null` metas is "not read yet", which is what the tab draws its loading
 *  state from; a place that answered with an error lands as a null entry
 *  and keeps its card, dateless. */
export function usePackagePlaces(
  kind: ItemKind,
  name: string,
  scopes: Scope[],
): { places: PackagePlace[]; loading: boolean } {
  const rows = useUpdatesStore((s) => s.rows);
  // Read field by field rather than through one selector: `rowUnsettled`
  // takes the state, and a selector returning a fresh object or closure
  // each render is a new value on every store touch.
  const updatesRead = useUpdatesStore((s) => s.read);
  const checking = useUpdatesStore((s) => s.checking);
  const reading = useUpdatesStore((s) => s.reading);
  const pendingFollows = useUpdatesStore((s) => s.pendingFollows);
  // Who owns each copy. Read beside the records rather than trusted from
  // an earlier visit: a rescan refreshes the join behind every write, but a
  // refresh that failed leaves the previous rows standing, and a stale
  // snapshot would hide Remove on a package that was just installed.
  const provenance = useProvenanceStore((s) => s.rows);
  const reloadProvenance = useProvenanceStore((s) => s.reload);
  // What is actually installed in each place, harness by harness. The join
  // answers per harness too, so this is what says whether every one of a
  // place's copies is accounted for.
  const installed = useScanStore((s) => s.result?.items);
  const [read, setRead] = useState<Read | null>(null);
  // The scan rebuilds the group on every read, so what is watched is which
  // places those are, not the array they arrived in.
  const subject = `${kind}|${name}|${scopes.map(scopeKey).join("|")}`;
  // An update rewrites the install date in the place it landed, and the
  // date lives only in that place's own record — so the records are read
  // again when the commits behind them move, and at no other store touch.
  const commits = installedCommits(rows, kind, name, scopes);
  const shown = useRef(subject);
  // biome-ignore lint/correctness/useExhaustiveDependencies: which places and which copies, not which array
  useEffect(() => {
    let cancelled = false;
    // Blanked only for a different package or a different set of places.
    // A re-read after an update replaces the dates under cards that are
    // already on screen rather than flashing the loading state over them.
    if (shown.current !== subject) {
      shown.current = subject;
      setRead(null);
    }
    void Promise.all([
      // Both reads settle before any card draws: a card is its date and
      // what can be done to the copy, and half of that is not a card.
      reloadProvenance(),
      Promise.all(
        scopes.map(async (scope) => {
          try {
            const response = await commands.packageMeta(scope, kind, name);
            return [
              scopeKey(scope),
              response.status === "ok" ? response.data : null,
            ] as const;
          } catch {
            // The generated wrapper rethrows a transport failure, and one
            // rejection would take the whole `Promise.all` with it: the
            // places that answered would be thrown away and the tab would
            // load forever. A place nobody could reach is a dateless card,
            // the same as one whose record did not read.
            return [scopeKey(scope), null] as const;
          }
        }),
      ),
    ]).then(([joined, pairs]) => {
      if (!cancelled) setRead({ metas: Object.fromEntries(pairs), joined });
    });
    return () => {
      cancelled = true;
    };
  }, [subject, commits, reloadProvenance]);

  return {
    places: packagePlaces(
      scopes,
      kind,
      name,
      rows,
      read?.metas ?? {},
      { read: updatesRead, checking, reading, pendingFollows },
      // A read that failed leaves the store's older rows in place, and
      // those say nothing about who owns these copies now. Passing none
      // holds the removal controls closed rather than deriving a
      // destructive button from a snapshot that may have gone stale.
      read?.joined ? provenance : [],
      installed ?? [],
    ),
    loading: read === null,
  };
}
