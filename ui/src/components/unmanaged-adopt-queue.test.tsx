// Adopting several installations is a queue, not a burst: each one rewrites
// a scope's files under that scope's lock, so two in flight at once means
// all but the first are refused as busy. `UnmanagedItems.adoptAll` awaits
// between installations to keep them in line, which only works if what it
// awaits is the write. A caller that hands back nothing turns every await
// into a no-op and the queue into a race.
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { NotManagedPanel } from "@/components/library/not-managed";
import { UnmanagedPage } from "@/pages/unmanaged";

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so both stores are wrapped rather than written to.
const stub = vi.hoisted(() => ({
  adopt: (() => {}) as (...args: unknown[]) => unknown,
}));

const view = vi.hoisted(() => ({
  scope: { scope: "global" },
  drift: [
    {
      kind: "skill",
      name: "gh",
      harness: "claude",
      scope: { scope: "global" },
      state: "unmanaged",
      detail: "/home/me/.claude/skills/gh",
      subject: "package",
    },
  ],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  heldBack: [],
  queued: [],
}));

vi.mock("@/stores/audit", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/audit")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useAuditStore.getState(),
      views: [view],
      busy: false,
      adopt: stub.adopt,
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useAuditStore: Object.assign(hook, mod.useAuditStore) };
});

vi.mock("@/stores/nav", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/nav")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useNavStore.getState(), libraryScope: "all" };
    return selector ? selector(state) : state;
  };
  return { ...mod, useNavStore: Object.assign(hook, mod.useNavStore) };
});

/** The list is mocked to hand back what it was given, since what is under
 *  test is what each page passes it. */
const seen = vi.hoisted(() => ({
  onAdopt: null as null | ((...args: unknown[]) => unknown),
}));
vi.mock("@/components/unmanaged-items", () => ({
  UnmanagedItems: (props: { onAdopt: (...args: unknown[]) => unknown }) => {
    seen.onAdopt = props.onAdopt;
    return null;
  },
}));

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((keep) => {
    resolve = keep;
  });
  return { promise, resolve };
}

beforeEach(() => {
  seen.onAdopt = null;
});

/** Every queued microtask, so "has not settled" means it, rather than
 *  meaning "has not settled yet in this tick". Racing two promises would
 *  not do: both are already resolved when the callback hands back nothing,
 *  and the race would time their microtasks instead of asking the
 *  question. */
const settle = () => new Promise((done) => setTimeout(done, 0));

/** Hand the page an adoption that has not finished, and watch what the
 *  caller got back: it must still be waiting while the write is in flight,
 *  and finish once it lands. Both halves matter — a callback that hands
 *  back a promise which never resolves would hang the queue instead of
 *  racing it. */
const waitsForTheWrite = async (render: () => void) => {
  const write = deferred<boolean>();
  stub.adopt = () => write.promise;
  render();
  if (!seen.onAdopt) throw new Error("the list was never handed an adopt");

  let finished = false;
  void Promise.resolve(seen.onAdopt("skill", "gh", "claude", {})).then(() => {
    finished = true;
  });

  await settle();
  const waited = !finished;
  write.resolve(true);
  await settle();
  return { waited, finished };
};

describe("adopting several installations one at a time", () => {
  it("hands back the write from the unmanaged page", async () => {
    expect(
      await waitsForTheWrite(() => renderToStaticMarkup(<UnmanagedPage />)),
    ).toEqual({ waited: true, finished: true });
  });

  it("hands back the write from the Library's panel", async () => {
    expect(
      await waitsForTheWrite(() => renderToStaticMarkup(<NotManagedPanel />)),
    ).toEqual({ waited: true, finished: true });
  });
});
