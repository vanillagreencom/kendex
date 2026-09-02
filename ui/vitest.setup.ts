import { afterEach, vi } from "vitest";

// Every zustand store this suite touches, captured as it is created and
// put back after each test.
//
// A store is a module-level singleton, so a test that writes one hands it
// to every test after it, in that file and in the same worker. Resetting
// per file was tried and did not hold: the round that added one to
// packages-table.test.tsx opened the same hole in detail-header.test.tsx
// in the same commit. The reset belongs where a test file cannot forget
// it — here, applying to every store, everywhere.
//
// `create` is wrapped rather than the stores being listed, so a store
// added later is covered without anyone remembering to add it.
const initial = new Map<
  { setState: (state: never, replace: true) => void },
  unknown
>();

vi.mock("zustand", async (importOriginal) => {
  const zustand = await importOriginal<typeof import("zustand")>();
  const track = <T,>(api: T): T => {
    const store = api as {
      getState: () => unknown;
      setState: (state: never, replace: true) => void;
    };
    initial.set(store, store.getState());
    return api;
  };
  const create = ((maker?: unknown) =>
    maker === undefined
      ? (later: unknown) => track(zustand.create(later as never))
      : track(zustand.create(maker as never))) as typeof zustand.create;
  return { ...zustand, create, default: create };
});

afterEach(() => {
  for (const [store, state] of initial) {
    store.setState(state as never, true);
  }
});
