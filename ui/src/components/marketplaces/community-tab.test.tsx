// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { DirectoryRow } from "@/bindings";
import {
  DIRECTORY_KENDEX_LABEL,
  DIRECTORY_SKILLSSH_LABEL,
} from "@/lib/copy-marketplaces";
import { useCommunityStore } from "@/stores/community";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { mount } from "@/test/dom";
import { CommunityTab } from "./community-tab";

// The Skills.sh panel reaches for the leaderboard on mount, and no backend
// answers here. This test is about the switcher, not the panel behind it.
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

const load = vi.fn(async () => {});

beforeEach(() => {
  load.mockReset();
  useMarketplacesStore.setState({ rows: [] });
  useCommunityStore.setState({
    directory: null,
    loading: false,
    error: null,
    skillsshAvailable: true,
    load,
  });
});

/** Every card's name, in the order the grid draws them. */
const namesOnScreen = (host: HTMLElement): string[] =>
  [...host.querySelectorAll("button")]
    .map((button) => button.querySelector("span")?.textContent ?? "")
    .filter((name) => name !== "");

const draw = () => mount(<CommunityTab />);

// Featured first is what the grid promises. Only the list can be asked
// about ordering — directory-card.test.tsx sees one card at a time.
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
    expect(namesOnScreen(draw())).toEqual(["zulu", "alpha"]);
  });

  it("falls back to name where nothing is featured", () => {
    useCommunityStore.setState({
      directory: {
        rows: [
          listed({ repo: "acme/zulu", name: "zulu" }),
          listed({ repo: "acme/alpha", name: "alpha" }),
        ],
        fetchedAt: "2026-09-02",
        stale: false,
      },
    });
    expect(namesOnScreen(draw())).toEqual(["alpha", "zulu"]);
  });
});

// The availability check is a round trip to kendex.ai that starts out
// true, so the control has to stay on screen for anyone who chose Skills.sh
// inside that window — unmounting it would strand them there.
describe("when the source switcher is on screen", () => {
  // The control is a fieldset whose legend names the group; the legend is
  // screen-reader-only, so the fieldset is what a query can hold on to.
  const switcher = (host: HTMLElement) => host.querySelector("fieldset");

  it("is drawn while Skills.sh is available", () => {
    const host = draw();
    expect(switcher(host)).not.toBeNull();
    expect(host.textContent).toContain(DIRECTORY_KENDEX_LABEL);
    expect(host.textContent).toContain(DIRECTORY_SKILLSSH_LABEL);
  });

  it("is not drawn when Skills.sh is unavailable and the directory is shown", () => {
    useCommunityStore.setState({ skillsshAvailable: false });
    expect(switcher(draw())).toBeNull();
  });

  it("stays drawn when Skills.sh goes unavailable under someone reading it", async () => {
    const host = draw();
    const skillssh = [
      ...host.querySelectorAll<HTMLInputElement>('input[type="radio"]'),
    ][1];
    await userEvent.click(skillssh);
    expect(host.querySelector('[data-testid="skillssh-panel"]')).not.toBeNull();

    // The availability check answers, late and negative.
    await act(async () => {
      useCommunityStore.setState({ skillsshAvailable: false });
    });

    expect(switcher(host)).not.toBeNull();
  });
});
