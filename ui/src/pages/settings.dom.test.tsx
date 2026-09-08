// @vitest-environment jsdom
// The About row reads the running version off a command, and the read is
// the page's only one. `app_version` cannot refuse — it answers a `Result`
// so a transport failure folds into the same reply (`specta_builder` in
// `crates/app/src/lib.rs`), which is the only failure this row ever draws.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { mount, settle } from "@/test/dom";
import { SettingsPage } from "./settings";

vi.mock("@/bindings", () => ({
  commands: {
    appVersion: vi.fn(),
    accountLoginStart: vi.fn(),
    accountLoginPoll: vi.fn(),
    accountLogout: vi.fn(),
    openUrl: vi.fn(),
    termsState: vi.fn().mockResolvedValue({
      status: "ok",
      data: { ask: false, accepted: null },
    }),
  },
  ZOOM: { min: 50, max: 200, step: 10, default: 100 },
  LEGAL: {
    version: 1,
    termsUrl: "https://kendex.ai/legal/terms",
    privacyUrl: "https://kendex.ai/legal/privacy",
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

beforeEach(() => vi.clearAllMocks());

describe("the version read outcome", () => {
  const rows = [
    {
      name: "draws the version the command answered with",
      response: { status: "ok", data: "5.0.1" },
      version: "5.0.1",
      error: null,
    },
    {
      name: "says the version could not be read when the command answers an error",
      response: { status: "error", error: "the bridge closed" },
      version: "unavailable",
      error: "the bridge closed",
    },
  ] as const;
  expect(rows).toHaveLength(2);
  it.each(rows)("$name", async (row) => {
    vi.mocked(commands.appVersion).mockResolvedValue(row.response);
    const host = mount(<SettingsPage />);
    await settle();
    const alert = host.querySelector('[role="alert"]');
    expect(
      {
        version: host.textContent?.includes(row.version),
        alert: alert !== null,
        reason:
          row.error === null ? null : alert?.textContent?.includes(row.error),
        unavailable:
          row.error === null ? null : alert?.textContent?.includes(row.version),
      },
      row.name,
    ).toEqual({
      version: true,
      alert: row.error !== null,
      reason: row.error === null ? null : true,
      unavailable: row.error === null ? null : true,
    });
  });
});
