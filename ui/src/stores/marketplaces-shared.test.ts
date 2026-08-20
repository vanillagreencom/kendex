import { describe, expect, it } from "vitest";
import {
  bundleKey,
  catalogKey,
  catalogLabel,
  isRepoKey,
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

  it("tells repository keys from subscription keys", () => {
    expect(isRepoKey(catalogKey({ by: "repo", repo: "acme/kit" }))).toBe(true);
    expect(
      isRepoKey(catalogKey(subscription({ scope: "global" }, "repo"))),
    ).toBe(false);
  });

  it("keeps a set named like a read off that read's key", () => {
    const catalog = subscription({ scope: "global" }, "kendex");
    expect(bundleKey(catalog, "packages")).not.toBe(
      readErrorKey(catalogKey(catalog), "packages"),
    );
  });
});
