// @vitest-environment jsdom
// The template page's two file reads, and what it draws when they fail.
//
// Both are shipped failure paths — templateFiles and templateFile already
// answer as status "error" — and collapsing them turned an unreadable
// store into the no-copies empty state and a read error into the file
// pane's contents. A claim about what a template holds is only made over
// a read that answered.
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Resolution, Template_Serialize } from "@/bindings";
import { commands } from "@/bindings";
import { COPY_PATH_LABEL } from "@/lib/copy";
import { FILES_UNREADABLE, NO_FILES } from "@/lib/copy-templates";
import { useNavStore } from "@/stores/nav";
import { useTemplatesStore } from "@/stores/templates";
import { mount, settle } from "@/test/dom";
import { TemplatePage } from "./template";

vi.mock("@/bindings", () => ({
  commands: {
    templatesList: vi.fn(),
    templateResolve: vi.fn(),
    templateFiles: vi.fn(),
    templateFile: vi.fn(),
    templateRemoveMembers: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const TEMPLATE: Template_Serialize = {
  name: "Rust service",
  id: "rust-service",
  members: [],
  customizations: {},
};

const RESOLVED: Resolution = { groups: [], copies: [], missing: [] };

beforeEach(() => {
  vi.clearAllMocks();
  useTemplatesStore.setState({
    templates: [TEMPLATE],
    everRead: true,
    read: { status: "read" },
    busy: false,
    refused: null,
  });
  useNavStore.setState({ page: "template", templateName: "Rust service" });
  vi.mocked(commands.templatesList).mockResolvedValue({
    status: "ok",
    data: [TEMPLATE],
  });
  vi.mocked(commands.templateResolve).mockResolvedValue({
    status: "ok",
    data: RESOLVED,
  });
});

describe("the files a template owns", () => {
  it("says the read failed instead of claiming there are no copies", async () => {
    vi.mocked(commands.templateFiles).mockResolvedValue({
      status: "error",
      error: "the template's store could not be read",
    });
    const host = mount(<TemplatePage />);
    await settle();

    expect(host.textContent).toContain(FILES_UNREADABLE);
    expect(host.textContent).not.toContain(NO_FILES);
  });

  it("claims there are no copies only over a read that answered", async () => {
    vi.mocked(commands.templateFiles).mockResolvedValue({
      status: "ok",
      data: [],
    });
    const host = mount(<TemplatePage />);
    await settle();

    expect(host.textContent).toContain(NO_FILES);
    expect(host.textContent).not.toContain(FILES_UNREADABLE);
  });

  it("never renders a failed file read as the file's contents", async () => {
    vi.mocked(commands.templateFiles).mockResolvedValue({
      status: "ok",
      data: [
        { path: "skills/house-style/SKILL.md", size: 12, isReadme: false },
      ],
    });
    vi.mocked(commands.templateFile).mockResolvedValue({
      status: "error",
      error: "that file is not text",
    });
    const host = mount(<TemplatePage />);
    await settle();

    const file = [...host.querySelectorAll<HTMLElement>("button")].find((one) =>
      one.textContent?.includes("SKILL.md"),
    );
    if (!file) throw new Error("no file row in the tree");
    await act(async () => file.click());
    await settle();

    // The reason is on screen as a failure, and no file pane was drawn
    // to render it into — the pane's own Copy path control is the tell.
    expect(host.textContent).toContain("that file is not text");
    const pane = [...host.querySelectorAll("button")].some(
      (one) => one.getAttribute("aria-label") === COPY_PATH_LABEL,
    );
    expect(pane).toBe(false);
  });
});
