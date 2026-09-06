import { beforeEach, describe, expect, it, vi } from "vitest";
import { useNavStore } from "@/stores/nav";

const deepLinkTake = vi.fn();
const listen = vi.fn();
vi.mock("@/bindings", () => ({
  commands: { deepLinkTake: (...args: unknown[]) => deepLinkTake(...args) },
  events: {
    deepLinkOpened: { listen: (...args: unknown[]) => listen(...args) },
  },
}));
const toastError = vi.fn();
vi.mock("sonner", () => ({ toast: { error: (m: string) => toastError(m) } }));

import { follow, receiveDeepLinks } from "./deep-link";

describe("deep links", () => {
  beforeEach(() => {
    useNavStore.getState().setPage("home");
    deepLinkTake.mockReset();
    listen.mockReset();
    toastError.mockReset();
  });

  it("opens a marketplace the way the Community tab opens a repository", () => {
    follow({ open: "marketplace", repo: "acme/kit" });
    const state = useNavStore.getState();
    expect(state.page).toBe("marketplaceDetail");
    expect(state.marketplaceRef).toEqual({ by: "repo", repo: "acme/kit" });
  });

  it("opens a package on its repository's package page", () => {
    follow({ open: "package", repo: "acme/kit", kind: "agent", name: "gen" });
    const state = useNavStore.getState();
    expect(state.page).toBe("availablePackage");
    expect(state.availableRef).toEqual({
      catalog: { by: "repo", repo: "acme/kit" },
      kind: "agent",
      name: "gen",
    });
  });

  it("lands a refused link on the marketplace list with the reason said", () => {
    follow({ open: "refused", reason: "kendex can't open x: no." });
    expect(useNavStore.getState().page).toBe("marketplaces");
    expect(toastError).toHaveBeenCalledWith("kendex can't open x: no.");
  });

  it("listens before it asks, follows the launching link, then the emitted ones", async () => {
    const order: string[] = [];
    type Emit = (event: { payload: unknown }) => void;
    const listeners: Emit[] = [];
    const unlisten = vi.fn();
    listen.mockImplementation(async (cb: Emit) => {
      order.push("listen");
      listeners.push(cb);
      return unlisten;
    });
    deepLinkTake.mockImplementation(async () => {
      order.push("take");
      return { open: "marketplace", repo: "acme/launched" };
    });

    const stop = await receiveDeepLinks();
    expect(order).toEqual(["listen", "take"]);
    expect(useNavStore.getState().marketplaceRef).toEqual({
      by: "repo",
      repo: "acme/launched",
    });

    for (const emit of listeners) {
      emit({ payload: { open: "marketplace", repo: "acme/later" } });
    }
    expect(useNavStore.getState().marketplaceRef).toEqual({
      by: "repo",
      repo: "acme/later",
    });
    expect(stop).toBe(unlisten);
  });

  it("asks a second time when the first ask is lost, then follows", async () => {
    listen.mockResolvedValue(() => {});
    deepLinkTake
      .mockRejectedValueOnce(new Error("no transport"))
      .mockResolvedValueOnce({ open: "marketplace", repo: "acme/retried" });
    await receiveDeepLinks();
    expect(deepLinkTake).toHaveBeenCalledTimes(2);
    expect(toastError).not.toHaveBeenCalled();
    expect(useNavStore.getState().marketplaceRef).toEqual({
      by: "repo",
      repo: "acme/retried",
    });
  });

  it("says when the launching link could not be asked for twice", async () => {
    listen.mockResolvedValue(() => {});
    deepLinkTake.mockRejectedValue(new Error("no transport"));
    await receiveDeepLinks();
    expect(deepLinkTake).toHaveBeenCalledTimes(2);
    expect(toastError).toHaveBeenCalledWith(
      expect.stringContaining("no transport"),
    );
    expect(useNavStore.getState().page).toBe("home");
  });
});
