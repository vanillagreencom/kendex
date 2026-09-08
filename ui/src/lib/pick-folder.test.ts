import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { pickFolder } from "./pick-folder";

vi.mock("@/bindings", () => ({
  commands: { pickFolder: vi.fn() },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn() },
}));

describe("pickFolder", () => {
  beforeEach(() => vi.mocked(toast.error).mockClear());

  it("returns each picker outcome and only reports failures", async () => {
    const rows: {
      name: string;
      response: Awaited<ReturnType<typeof commands.pickFolder>>;
      path: string | null;
      errors: string[][];
    }[] = [
      {
        name: "chosen folder",
        response: { status: "ok", data: "/home/x/acme-web" },
        path: "/home/x/acme-web",
        errors: [],
      },
      {
        name: "cancelled picker",
        response: { status: "ok", data: null },
        path: null,
        errors: [],
      },
      {
        name: "picker failure",
        response: { status: "error", error: "picker unavailable" },
        path: null,
        errors: [["picker unavailable"]],
      },
    ];
    expect(rows.length, "folder picker outcome table is empty").toBeGreaterThan(
      0,
    );
    for (const row of rows) {
      vi.mocked(toast.error).mockClear();
      vi.mocked(commands.pickFolder).mockResolvedValue(row.response);
      const path = await pickFolder();
      expect(
        { path, errors: vi.mocked(toast.error).mock.calls },
        row.name,
      ).toEqual({ path: row.path, errors: row.errors });
    }
  });
});
