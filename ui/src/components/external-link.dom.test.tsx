// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { mount } from "@/test/dom";
import { ExternalLink } from "./external-link";

vi.mock("@/bindings", () => ({
  commands: { openUrl: vi.fn() },
}));

const click = async (host: HTMLElement) => {
  const button = host.querySelector("button");
  if (!button) throw new Error("no link rendered");
  await act(async () => {
    await userEvent.click(button);
  });
};

beforeEach(() => {
  vi.mocked(commands.openUrl).mockReset();
});

describe("a link out of the app", () => {
  it("hands the URL to the system opener rather than the app's own window", async () => {
    vi.mocked(commands.openUrl).mockResolvedValue({ status: "ok", data: null });
    const host = mount(
      <ExternalLink url="https://github.com/acme/kit">acme/kit</ExternalLink>,
    );
    await click(host);
    expect(commands.openUrl).toHaveBeenCalledWith(
      "https://github.com/acme/kit",
    );
  });

  // A catalog writes its own homepage, and which URLs may be opened is the
  // `open_url` command's rule. A refused click has to say so: silence would
  // read as a link that does nothing.
  it("shows the refusal when the URL is one the app will not open", async () => {
    vi.mocked(commands.openUrl).mockResolvedValue({
      status: "error",
      error: "only web pages can be opened",
    });
    const host = mount(
      <ExternalLink url="file:///etc/passwd">home page</ExternalLink>,
    );
    await click(host);
    expect(host.textContent).toContain("only web pages can be opened");
    expect(host.querySelector('[role="alert"]')).not.toBeNull();
  });
});
