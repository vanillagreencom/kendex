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
        const response = await commands.packageMeta(scope, kind, name);
        return [
          scopeKey(scope),
          response.status === "ok" ? response.data : null,
        ] as const;
      }),
    ).then((pairs) => {
      if (!cancelled) setMetas(Object.fromEntries(pairs));
    });
    return () => {
      cancelled = true;
    };
  }, [key, kind, name]);

  return {
    places: packagePlaces(scopes, kind, name, rows, metas ?? {}),
    loading: metas === null,
  };
}
