// @vitest-environment jsdom
// What a page browsing a bare repository offers before it can match the
// repository against anything. The overview read is what says whether that
// is worth waiting for: one still out answers on its own, one that failed
// never will, and a control that says "Checking subscriptions…" over a read
// that is over and failed is a dead button with a false reason on it.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { DirectoryView } from "@/bindings";
import { RepoAction } from "@/components/marketplaces/repo-action";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import { READ_PENDING, readFailed } from "@/lib/read-state";
import { useCommunityStore } from "@/stores/community";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { mount, settle } from "@/test/dom";

vi.mock("@/bindings", () => ({
  commands: { marketplacesOverview: vi.fn(), sourcesRefresh: vi.fn() },
}));
vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), message: vi.fn() },
}));

const CHECKING = "Checking subscriptions…";

/** The directory as served, carrying the canonical key for the repository
 *  this page is browsing. */
const listing: DirectoryView = {
  rows: [
    {
      repo: "acme/kit",
      repoKey: "acme/kit",
      name: "kit",
      description: null,
      tags: [],
      featured: false,
      packageCount: 0,
      bundleCount: 0,
      subscribed: false,
      packages: [],
      bundles: [],
    },
  ],
  fetchedAt: "2026-08-31T00:00:00Z",
  stale: false,
};

const draw = () =>
  mount(
    <RepoAction repo="acme/kit" summary={null} subscribeLabel="Subscribe" />,
  );

const buttons = (host: HTMLElement) =>
  [...host.querySelectorAll("button")].map((one) => one.textContent);

beforeEach(() => {
  vi.clearAllMocks();
  useCommunityStore.setState({ directory: null });
  // No rows and no key: the arm under test, whatever the read did.
  useMarketplacesStore.setState({ rows: [], read: READ_PENDING });
});

describe("a repository page with nothing to match against", () => {
  it("says it is checking while the read is still out", () => {
    const host = draw();
    expect(buttons(host)).toContain(CHECKING);
  });

  // The other reason this arm is reached: the repository has no canonical
  // key yet, from the summary or the directory row. The overview read is
  // not what is holding it, so retrying the overview would change nothing
  // the person can see — the wait is real and the control says so.
  it("waits, rather than offering a retry, when the key is what is missing", () => {
    useMarketplacesStore.setState({
      rows: [],
      read: readFailed("the settings file is malformed"),
    });

    const host = mount(
      <RepoAction repo="acme/kit" summary={null} subscribeLabel="Subscribe" />,
    );

    expect(buttons(host)).toContain(CHECKING);
    expect(buttons(host)).not.toContain(TRY_AGAIN_LABEL);
  });

  // The failure this whole arm was added for. Nothing else on the page
  // mentions the subscription list — the page's own banner belongs to the
  // summary read — so without this there is no reason on screen and no way
  // back short of leaving and returning.
  it("offers the retry, not a dead check, once the read has failed", async () => {
    // The key is known — from the directory row — so the overview read is
    // the only thing left holding this neutral.
    useCommunityStore.setState({ directory: listing });
    useMarketplacesStore.setState({
      rows: [],
      read: readFailed("the settings file is malformed"),
    });

    const host = draw();

    expect(buttons(host)).toContain(TRY_AGAIN_LABEL);
    expect(buttons(host)).not.toContain(CHECKING);
    // The reason travels with it rather than being dropped.
    expect(host.innerHTML).toContain("the settings file is malformed");

    const retry = [...host.querySelectorAll("button")].find(
      (one) => one.textContent === TRY_AGAIN_LABEL,
    );
    if (!retry) throw new Error("no retry button");
    const { commands } = await import("@/bindings");
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [],
    });
    retry.click();
    await settle();

    expect(commands.marketplacesOverview).toHaveBeenCalled();
  });
});
