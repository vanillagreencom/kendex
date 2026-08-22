// One click that writes several places, and one of them refusing partway.
// The message comes from the place that failed, so the way out offered with
// it is that place's — and taking it finishes that place and stops, leaving
// the ones after it never attempted and nothing left on screen to say so.
// The click was about the package, so the retry has to be too.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Scope } from "@/bindings";
import { useEditorStore } from "./editor";
import { useProblemsStore } from "./problems";
import { inEveryPlace, retryTheRest } from "./unsaved-first";

vi.mock("@/bindings", () => ({ commands: {} }));

const A: Scope = { scope: "project", root: "/work/a" };
const B: Scope = { scope: "project", root: "/work/b" };
const C: Scope = { scope: "project", root: "/work/c" };

/** The funnel's own shape, narrowed to what this is about: an action that
 *  fails raises a dialog whose Retry is the rest of the job when there is
 *  one, and its own place when there is not. */
const funnel =
  (fails: Set<string>, wrote: string[]) => async (scope: Scope) => {
    const root = "root" in scope ? scope.root : "global";
    if (fails.has(root)) {
      const again = retryTheRest();
      useProblemsStore.getState().showError({
        title: "Couldn't do it here",
        message: root,
        actions: [
          { label: "Retry", onClick: again ?? (() => wrote.push("just me")) },
        ],
      });
      return false;
    }
    wrote.push(root);
    return true;
  };

beforeEach(() => {
  useEditorStore.setState({ scope: A, draft: null, dirty: false, held: {} });
  useProblemsStore.getState().closeError();
});

describe("a package-wide action that stopped partway", () => {
  it("offers the places that are left, not the one that failed", async () => {
    const wrote: string[] = [];
    const fails = new Set(["/work/b"]);

    await inEveryPlace([A, B, C], funnel(fails, wrote));
    expect(wrote).toEqual(["/work/a"]);

    // The reader presses Retry, and whatever was wrong with B is now fixed.
    const retry = useProblemsStore.getState().dialog.actions?.[0];
    fails.clear();
    retry?.onClick();
    await vi.waitUntil(() => wrote.length === 3);

    // B and C, in order — not B alone.
    expect(wrote).toEqual(["/work/a", "/work/b", "/work/c"]);
  });

  it("leaves a single place's retry its own", async () => {
    const wrote: string[] = [];
    // Not through inEveryPlace: one place acting for itself.
    await funnel(new Set(["/work/b"]), wrote)(B);

    const retry = useProblemsStore.getState().dialog.actions?.[0];
    retry?.onClick();
    expect(wrote).toEqual(["just me"]);
  });

  // The slot is only ever set while a place is being written, or a later
  // single-place failure would inherit a package-wide retry that has
  // nothing to do with it.
  it("keeps nothing once the action is over", async () => {
    await inEveryPlace([A, B], funnel(new Set(), []));
    expect(retryTheRest()).toBeNull();
  });

  // Including when the action does not return at all — a transport failure
  // rejects rather than answering, and the way out of the loop it takes
  // must still put this down.
  it("keeps nothing when a place throws instead of answering", async () => {
    await expect(
      inEveryPlace([A, B], async (scope) => {
        if (scope === A) return true;
        throw new Error("the channel closed");
      }),
    ).rejects.toThrow("the channel closed");

    expect(retryTheRest()).toBeNull();
  });
});
