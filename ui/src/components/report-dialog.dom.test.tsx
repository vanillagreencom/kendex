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
  it("shows fallback warnings only for the route that carries them", async () => {
    const rows = [
      {
        name: "unreadable record",
        expectedWarning: true,
        warnings: ["install record unreadable: old record"],
      },
      { name: "clean route", expectedWarning: false, warnings: [] },
    ];
    expect(rows).toHaveLength(2);
    for (const row of rows) {
      vi.mocked(commands.reportRoute).mockResolvedValue({
        status: "ok",
        data: {
          kendexOwned: true,
          repo: "vanillagreencom/kendex",
          label: "skills",
          issueUrl: "https://github.com/vanillagreencom/kendex/issues/new",
          warnings: row.warnings,
        },
      });
      const host = mount(
        <ReportDialog scope={PROJECT} name="gh" kind="skill" />,
      );
      await userEvent.click(host.querySelector("button") as HTMLButtonElement);
      await settle();
      const open = document.querySelector('[role="dialog"]');
      expect(open).not.toBeNull();
      if (row.expectedWarning) {
        expect(open?.textContent, row.name).toContain(
          "Routing used fallback evidence",
        );
        expect(open?.textContent, row.name).toContain(
          "install record unreadable: old record",
        );
      } else {
        expect(open?.textContent, row.name).not.toContain(
          "Routing used fallback evidence",
        );
      }
      const close = [...(open?.querySelectorAll("button") ?? [])].find(
        (button) => button.textContent === "Close",
      );
      if (!close) throw new Error("no close button");
      await userEvent.click(close);
      await settle();
    }
  });
});
