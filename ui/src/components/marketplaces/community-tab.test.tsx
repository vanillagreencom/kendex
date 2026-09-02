// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { DirectoryRow } from "@/bindings";
import { useCommunityStore } from "@/stores/community";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { mount } from "@/test/dom";
import { CommunityTab } from "./community-tab";

// The Skills.sh panel reaches for the leaderboard on mount, and no backend
// answers here. This is about the grid, not the panel behind it.
vi.mock("./skillssh-search", () => ({
  SkillsShSearch: () => <div data-testid="skillssh-panel" />,
}));

const listed = (over: Partial<DirectoryRow> = {}): DirectoryRow => ({
  repo: "acme/kit",
  repoKey: "acme/kit",
  name: "kit",
  description: null,
  tags: [],
  featured: false,
  packageCount: 1,
  bundleCount: 0,
  subscribed: false,
  packages: [],
  bundles: [],
  ...over,
});

beforeEach(() => {
  useMarketplacesStore.setState({ rows: [] });
  useCommunityStore.setState({
    directory: null,
    loading: false,
    error: null,
    skillsshAvailable: true,
    load: vi.fn(async () => {}),
  });
});

// Featured leads, then name. No source the app receives publishes installs
// or stars, so this is the order the grid actually promises — and only the
// list can be asked about it, since directory-card.test.tsx sees one card
// at a time.
describe("the order the community grid draws its cards", () => {
  it("puts a featured marketplace above one listed before it", () => {
    useCommunityStore.setState({
      directory: {
        rows: [
          listed({ repo: "acme/alpha", name: "alpha" }),
          listed({ repo: "acme/zulu", name: "zulu", featured: true }),
        ],
        fetchedAt: "2026-09-02",
        stale: false,
      },
    });
    const host = mount(<CommunityTab />);
    const names = [...host.querySelectorAll("button")]
      .map((button) => button.querySelector("span")?.textContent ?? "")
      .filter((name) => name !== "");

    expect(names).toEqual(["zulu", "alpha"]);
  });
});
