import { useEffect, useState } from "react";
import {
  commands,
  type ItemKind,
  type PackageMeta_Serialize,
  type Scope,
} from "@/bindings";
import { type PackagePlace, packagePlaces } from "@/lib/package-places";
import { scopeKey } from "@/lib/scope";
import { useUpdatesStore } from "@/stores/updates";

type Metas = Record<string, PackageMeta_Serialize | null>;

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
  const loaded = useUpdatesStore((s) => s.loaded);
  const checking = useUpdatesStore((s) => s.checking);
  const overviewInFlight = useUpdatesStore((s) => s.overviewInFlight);
  const pendingFollows = useUpdatesStore((s) => s.pendingFollows);
  const [metas, setMetas] = useState<Metas | null>(null);
  // The scan rebuilds the group on every read, so what is watched is which
  // places those are, not the array they arrived in.
  const key = scopes.map(scopeKey).join("|");
  // biome-ignore lint/correctness/useExhaustiveDependencies: which places, not which array
  useEffect(() => {
    let cancelled = false;
    setMetas(null);
    void Promise.all(
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
    ).then((pairs) => {
      if (!cancelled) setMetas(Object.fromEntries(pairs));
    });
    return () => {
      cancelled = true;
    };
  }, [key, kind, name]);

  return {
    places: packagePlaces(scopes, kind, name, rows, metas ?? {}, {
      loaded,
      checking,
      overviewInFlight,
      pendingFollows,
    }),
    loading: metas === null,
  };
}
