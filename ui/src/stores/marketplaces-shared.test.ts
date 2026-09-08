import { describe, expect, it } from "vitest";
import {
  bundleKey,
  catalogKey,
  catalogLabel,
  marketKey,
  readErrorKey,
  subscription,
} from "./marketplaces-shared";

describe("catalog addressing", () => {
  it("keys a subscription the way its rows were cached", () => {
    const scope = { scope: "project" as const, root: "/work/acme" };
    expect(catalogKey(subscription(scope, "kendex"))).toBe(
      marketKey(scope, "kendex"),
    );
  });

  it("keeps repository keys separate from subscription keys", () => {
    const rows = [
      {
        name: "project root named repo",
        catalog: subscription({ scope: "project", root: "repo" }, "acme/kit"),
        repo: "acme/kit",
      },
      {
        name: "global alias named as repository",
        catalog: subscription({ scope: "global" }, "acme/kendex"),
        repo: "acme/kendex",
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      const repo = catalogKey({ by: "repo", repo: row.repo });
      expect(repo, row.name).not.toBe(catalogKey(row.catalog));
      expect(repo, row.name).toBe(catalogKey({ by: "repo", repo: row.repo }));
    }
  });

  it("labels a catalog by its alias or its repository", () => {
    const rows = [
      {
        name: "alias",
        catalog: subscription({ scope: "global" }, "kendex"),
        expected: "kendex",
      },
      {
        name: "repository",
        catalog: { by: "repo" as const, repo: "wshobson/agents" },
        expected: "wshobson/agents",
      },
      { name: "no catalog", catalog: undefined, expected: null },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows)
      expect(catalogLabel(row.catalog), row.name).toBe(row.expected);
  });

  it("keeps a set named like a read off that read's key", () => {
    const catalog = subscription({ scope: "global" }, "kendex");
    expect(bundleKey(catalog, "packages", null)).not.toBe(
      readErrorKey(catalogKey(catalog), "packages"),
    );
  });
});
