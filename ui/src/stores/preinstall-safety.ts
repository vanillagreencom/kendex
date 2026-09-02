import { create } from "zustand";
import {
  type Catalog,
  commands,
  type ItemKind,
  type PackageSafety,
} from "@/bindings";
import { catalogDrops, catalogKey } from "./marketplaces-shared";

/** One offered package's identity across every marketplace query. */
export const safetyKey = (
  catalog: Catalog,
  kind: ItemKind,
  name: string,
): string => `${catalogKey(catalog)}::${kind}::${name}`;

interface PreinstallSafetyState {
  /** Answered scores; a key in flight or failed is simply absent, and the
   * dot stays quiet rather than guessing. */
  scores: Record<string, PackageSafety>;
  /** Queue a package's score. Fetches drain one at a time — a table of
   * forty rows must not fire forty scans at once; the backend caches, so a
   * revisit answers from disk. */
  want: (catalog: Catalog, kind: ItemKind, name: string) => void;
}

interface QueueItem {
  catalog: Catalog;
  kind: ItemKind;
  name: string;
  key: string;
}

const queue: QueueItem[] = [];
const queued = new Set<string>();
let draining = false;

/** Empty the cache and the queue — half of [droppedSetCaches], which is
 * where a drop is declared and where the one [catalogDrops] bump is taken.
 * Call that rather than this: a scan already in flight would otherwise land
 * in the slot this just emptied, and `want` short-circuits on a stored
 * score, so nothing would ever ask again. */
export function resetPreinstallSafety() {
  queue.length = 0;
  queued.clear();
  usePreinstallSafety.setState({ scores: {} });
}

export const usePreinstallSafety = create<PreinstallSafetyState>(
  (set, get) => ({
    scores: {},
    want: (catalog, kind, name) => {
      const key = safetyKey(catalog, kind, name);
      if (get().scores[key] || queued.has(key)) return;
      queued.add(key);
      queue.push({ catalog, kind, name, key });
      if (draining) return;
      draining = true;
      void (async () => {
        try {
          while (queue.length > 0) {
            const item = queue.shift();
            if (!item) break;
            const began = catalogDrops.since();
            try {
              const response = await commands.marketplacePackagePreview(
                item.catalog,
                item.kind,
                item.name,
                // The safety reading is about the package's bytes, which
                // no destination changes.
                null,
              );
              // A drop while this was in flight emptied the slot it would
              // fill, and cleared `queued` with it: storing the old score
              // would pin the commit before the change, and dropping it
              // costs nothing because the next mount of the row asks again.
              if (catalogDrops.stale(began)) continue;
              if (response.status === "ok") {
                set((state) => ({
                  scores: {
                    ...state.scores,
                    [item.key]: response.data.safety,
                  },
                }));
              } else {
                // Retryable: the next mount of the row asks again instead
                // of showing "Checking…" forever.
                queued.delete(item.key);
              }
            } catch {
              // A transport error must not wedge the whole queue.
              queued.delete(item.key);
            }
          }
        } finally {
          draining = false;
        }
      })();
    },
  }),
);
