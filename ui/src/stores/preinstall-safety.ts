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
  /** Answered scores; a key in flight or failed is simply absent. */
  scores: Record<string, PackageSafety>;
  /** Hold demand while a row is visible or a consumer explicitly needs it.
   * Release removes queued work when the last consumer leaves. Running
   * reads finish, but only their own catalog generation can store them. */
  want: (catalog: Catalog, kind: ItemKind, name: string) => () => void;
}

interface QueueItem {
  catalog: Catalog;
  kind: ItemKind;
  name: string;
  key: string;
}

const queue = new Map<string, QueueItem>();
const demand = new Map<string, { item: QueueItem; consumers: Set<symbol> }>();
let running: { key: string; generation: number } | null = null;

function enqueue(item: QueueItem) {
  if (usePreinstallSafety.getState().scores[item.key] !== undefined) return;
  if (running?.key === item.key && running.generation === catalogDrops.since())
    return;
  queue.set(item.key, item);
  void drain();
}

async function drain() {
  if (running !== null) return;
  while (queue.size > 0) {
    const item = queue.values().next().value;
    if (!item) throw new Error("A nonempty safety queue has no first item");
    queue.delete(item.key);
    const began = catalogDrops.since();
    running = { key: item.key, generation: began };
    try {
      const response = await commands.marketplacePackagePreview(
        item.catalog,
        item.kind,
        item.name,
        // Safety describes the package's bytes, which no destination changes.
        null,
      );
      if (!catalogDrops.stale(began) && response.status === "ok") {
        usePreinstallSafety.setState((state) => ({
          scores: { ...state.scores, [item.key]: response.data.safety },
        }));
      }
      // A refusal leaves no score. The next acquisition can retry it.
    } catch {
      // A transport failure leaves no score and must not wedge the drain.
    } finally {
      running = null;
    }
  }
}

/** The score half of the shared catalog drop. Call [dropCatalogCaches] or
 * [droppedSetCaches] so the generation moves before the running read lands.
 * Demand survives the drop: mounted consumers need the replacement score. */
export function resetPreinstallSafety() {
  queue.clear();
  usePreinstallSafety.setState({ scores: {} });
  for (const { item } of demand.values()) enqueue(item);
}

export const usePreinstallSafety = create<PreinstallSafetyState>(() => ({
  scores: {},
  want: (catalog, kind, name) => {
    const key = safetyKey(catalog, kind, name);
    const consumer = Symbol();
    let held = demand.get(key);
    if (!held) {
      held = { item: { catalog, kind, name, key }, consumers: new Set() };
      demand.set(key, held);
    }
    held.consumers.add(consumer);
    enqueue(held.item);
    return () => {
      if (!held.consumers.delete(consumer)) return;
      if (held.consumers.size > 0) return;
      demand.delete(key);
      queue.delete(key);
    };
  },
}));
