// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type Scope } from "@/bindings";
import { mount, settle } from "@/test/dom";
import { ReportDialog } from "./report-dialog";

vi.mock("@/bindings", () => ({
  commands: { reportRoute: vi.fn() },
}));

const PROJECT: Scope = { scope: "project", root: "/work/acme" };

beforeEach(() => {
  vi.clearAllMocks();
});

describe("report routing with an unreadable install record", () => {
  it("shows the warning kept by fallback routing", async () => {
    vi.mocked(commands.reportRoute).mockResolvedValue({
      status: "ok",
      data: {
        kendexOwned: true,
        repo: "vanillagreencom/kendex",
        label: "skills",
        issueUrl: "https://github.com/vanillagreencom/kendex/issues/new",
        warnings: ["install record unreadable: old record"],
      },
    });
    const host = mount(<ReportDialog scope={PROJECT} name="gh" kind="skill" />);

    await userEvent.click(host.querySelector("button") as HTMLButtonElement);
    await settle();

    expect(document.body.textContent).toContain(
      "Routing used fallback evidence",
    );
    expect(document.body.textContent).toContain(
      "install record unreadable: old record",
    );
  });

  it("shows no fallback warning for a clean route", async () => {
    vi.mocked(commands.reportRoute).mockResolvedValue({
      status: "ok",
      data: {
        kendexOwned: true,
        repo: "vanillagreencom/kendex",
        label: "skills",
        issueUrl: "https://github.com/vanillagreencom/kendex/issues/new",
        warnings: [],
      },
    });
    const host = mount(<ReportDialog scope={PROJECT} name="gh" kind="skill" />);

    await userEvent.click(host.querySelector("button") as HTMLButtonElement);
    await settle();

    expect(document.body.textContent).not.toContain(
      "Routing used fallback evidence",
    );
  });
});
