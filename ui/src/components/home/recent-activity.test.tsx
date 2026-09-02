import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { RecentGroup } from "@/lib/derive";
import { exactTime } from "@/lib/relative-time";
import { RecentActivity } from "./recent-activity";

const AT = Date.UTC(2024, 0, 2, 3, 4, 5) / 1000;

const group: RecentGroup = {
  key: "skill:gh",
  kind: "skill",
  name: "gh",
  description: null,
  installations: [],
  harnesses: ["claude"],
  tags: [],
  shared: false,
  modifiedAt: AT,
};

// A reading coarse enough to say "2y ago" has thrown the date away, so the
// element carries the exact one. Without it a row a year old says only
// that, and there is nowhere left to find out when.
describe("a row's timestamp", () => {
  it("keeps the exact moment on the element showing the reading", () => {
    const html = renderToStaticMarkup(<RecentActivity groups={[group]} />);
    expect(html).toContain(`title="${exactTime(AT * 1000)}"`);
  });
});
