import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { SaveBar } from "./save-bar";

describe("SaveBar", () => {
  it("waits while another rewrite of the manifest is in flight", () => {
    const idle = renderToStaticMarkup(
      <SaveBar saving={false} onSave={() => {}} onDiscard={() => {}} />,
    );
    expect(idle).not.toMatch(/<button[^>]*disabled=""/);
    const gated = renderToStaticMarkup(
      <SaveBar saving={false} busy onSave={() => {}} onDiscard={() => {}} />,
    );
    expect(gated.match(/<button[^>]*disabled=""/g)).toHaveLength(2);
    expect(gated).toContain(">Save and apply<");
  });
});
