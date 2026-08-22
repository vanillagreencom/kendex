import { describe, expect, it } from "vitest";
import { showEverythingLabel } from "./project-card-label";

describe("showEverythingLabel", () => {
  it("separates two projects whose folders share a name", () => {
    expect(showEverythingLabel("client", "/work/client")).not.toBe(
      showEverythingLabel("client", "/personal/client"),
    );
  });

  it("names the folder a card opens", () => {
    expect(showEverythingLabel("client", "/work/client")).toBe(
      "Show everything in client, /work/client",
    );
  });

  it("keeps the name a reader sees inside the label", () => {
    expect(showEverythingLabel("client", "/work/client")).toContain("client");
  });

  it("says only the name where there is no folder", () => {
    expect(showEverythingLabel("Personal")).toBe("Show everything in Personal");
    expect(showEverythingLabel("Personal", "")).toBe(
      "Show everything in Personal",
    );
  });
});
