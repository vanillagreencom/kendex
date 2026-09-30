import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { dropCatalogCaches } from "./marketplaces-shared";
import { safetyKey, usePreinstallSafety } from "./preinstall-safety";

vi.mock("@/bindings", () => ({
  commands: { marketplacePackagePreview: vi.fn() },
}));

const catalog = { by: "repo" as const, repo: "ada/skills" };
const key = safetyKey(catalog, "skill", "deploy");
const releases: (() => void)[] = [];
const scored = (score: number) =>
  ({
    status: "ok" as const,
    data: { safety: { name: "deploy", safety: { score, deductions: [] } } },
  }) as never;

beforeEach(() => {
  vi.useFakeTimers();
  vi.mocked(commands.marketplacePackagePreview).mockReset();
  dropCatalogCaches(() => {});
});
afterEach(async () => {
  for (const release of releases.splice(0)) release();
  await vi.runAllTimersAsync();
  vi.useRealTimers();
});

const want = (name = "deploy") => {
  const release = usePreinstallSafety.getState().want(catalog, "skill", name);
  releases.push(release);
  return release;
};

describe("safety demand", () => {
  it("drops queued demand on last release, but lets a running read finish", async () => {
    let land: (value: unknown) => void = () => {};
    vi.mocked(commands.marketplacePackagePreview)
      .mockReturnValueOnce(
        new Promise((resolve) => {
          land = resolve;
        }) as never,
      )
      .mockResolvedValue(scored(40));
    const running = want();
    const first = want("offscreen");
    const second = want("offscreen");
    first();
    // A second visible consumer still needs this queued row.
    second();
    running();
    land(scored(90));
    await vi.runAllTimersAsync();
    expect(commands.marketplacePackagePreview).toHaveBeenCalledTimes(1);
    expect(usePreinstallSafety.getState().scores[key]?.safety.score).toBe(90);
    want("offscreen");
    await vi.runAllTimersAsync();
    expect(commands.marketplacePackagePreview).toHaveBeenCalledTimes(2);
  });

  it("keeps shared queued demand until its remaining consumer leaves", async () => {
    let land: (value: unknown) => void = () => {};
    vi.mocked(commands.marketplacePackagePreview)
      .mockReturnValueOnce(
        new Promise((resolve) => {
          land = resolve;
        }) as never,
      )
      .mockResolvedValue(scored(40));
    want();
    want("shared")();
    want("shared");
    land(scored(90));
    await vi.runAllTimersAsync();
    expect(
      vi
        .mocked(commands.marketplacePackagePreview)
        .mock.calls.map((call) => call[2]),
    ).toEqual(["deploy", "shared"]);
  });

  it("discards an invalidated answer and replaces only live demand", async () => {
    let land: (value: unknown) => void = () => {};
    vi.mocked(commands.marketplacePackagePreview)
      .mockReturnValueOnce(
        new Promise((resolve) => {
          land = resolve;
        }) as never,
      )
      .mockResolvedValue(scored(40));
    want();
    want("departed")();
    dropCatalogCaches(() => {});
    land(scored(90));
    await vi.runAllTimersAsync();
    expect(
      vi
        .mocked(commands.marketplacePackagePreview)
        .mock.calls.map((call) => call[2]),
    ).toEqual(["deploy", "deploy"]);
    expect(usePreinstallSafety.getState().scores[key]?.safety.score).toBe(40);
  });

  it("never stores a stale score after its consumer departs", async () => {
    let land: (value: unknown) => void = () => {};
    vi.mocked(commands.marketplacePackagePreview).mockReturnValueOnce(
      new Promise((resolve) => {
        land = resolve;
      }) as never,
    );
    want()();
    dropCatalogCaches(() => {});
    land(scored(90));
    await vi.runAllTimersAsync();
    expect(usePreinstallSafety.getState().scores[key]).toBeUndefined();
    expect(commands.marketplacePackagePreview).toHaveBeenCalledTimes(1);
  });

  it("coalesces running and answered demand", async () => {
    vi.mocked(commands.marketplacePackagePreview).mockResolvedValue(scored(90));
    want();
    want();
    await vi.runAllTimersAsync();
    want();
    await vi.runAllTimersAsync();
    expect(usePreinstallSafety.getState().scores[key]?.safety.score).toBe(90);
    expect(commands.marketplacePackagePreview).toHaveBeenCalledTimes(1);
  });

  it("retries refusals and transport failures on a new acquisition without wedging the queue", async () => {
    const failures = [
      () => Promise.resolve({ status: "error", error: "unreadable" }),
      () => Promise.reject(new Error("bridge closed")),
    ];
    for (const fail of failures) {
      dropCatalogCaches(() => {});
      vi.mocked(commands.marketplacePackagePreview).mockReset();
      vi.mocked(commands.marketplacePackagePreview)
        .mockImplementationOnce(fail as never)
        .mockResolvedValue(scored(40));
      const release = want();
      await vi.runAllTimersAsync();
      expect(usePreinstallSafety.getState().scores[key]).toBeUndefined();
      release();
      want();
      await vi.runAllTimersAsync();
      expect(usePreinstallSafety.getState().scores[key]?.safety.score).toBe(40);
      expect(commands.marketplacePackagePreview).toHaveBeenCalledTimes(2);
      for (const stop of releases.splice(0)) stop();
    }
  });
});
