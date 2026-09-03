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

  it("never lets a project root and alias spell a repository's key", () => {
    // A project checked out at a relative root named "repo", subscribed to
    // an alias that reads like a repository reference.
    const project = subscription(
      { scope: "project", root: "repo" },
      "acme/kit",
    );
    const repo = { by: "repo" as const, repo: "acme/kit" };
    expect(catalogKey(project)).not.toBe(catalogKey(repo));
  });

  it("never folds a repository into a subscription of the same name", () => {
    const repo = catalogKey({ by: "repo", repo: "acme/kendex" });
    expect(repo).not.toBe(
      catalogKey(subscription({ scope: "global" }, "acme/kendex")),
    );
    expect(repo).toBe(catalogKey({ by: "repo", repo: "acme/kendex" }));
  });

  it("labels a catalog by its alias or its repository", () => {
    expect(catalogLabel(subscription({ scope: "global" }, "kendex"))).toBe(
      "kendex",
    );
    expect(catalogLabel({ by: "repo", repo: "wshobson/agents" })).toBe(
      "wshobson/agents",
    );
    expect(catalogLabel(undefined)).toBeNull();
  });

  it("keeps a set named like a read off that read's key", () => {
    const catalog = subscription({ scope: "global" }, "kendex");
    expect(bundleKey(catalog, "packages", null)).not.toBe(
      readErrorKey(catalogKey(catalog), "packages"),
    );
  });
});
