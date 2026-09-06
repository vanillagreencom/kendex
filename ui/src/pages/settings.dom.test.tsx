// @vitest-environment jsdom
// The About row reads the running version off a command, and the read is
// the page's only one. `app_version` cannot refuse — it answers a `Result`
// so a transport failure folds into the same reply (`specta_builder` in
// `crates/app/src/lib.rs`), which is the only failure this row ever draws.
import { beforeEach, expect, it, vi } from "vitest";
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

it("draws the version the command answered with", async () => {
  vi.mocked(commands.appVersion).mockResolvedValue({
    status: "ok",
    data: "5.0.1",
  });

  const host = mount(<SettingsPage />);
  await settle();

  expect(host.textContent).toContain("5.0.1");
  expect(host.querySelector('[role="alert"]')).toBeNull();
});

// Without this the row sits on its ellipsis for the rest of the session and
// the person is told nothing at all about why the version never arrived.
it("says the version could not be read when the command answers an error", async () => {
  vi.mocked(commands.appVersion).mockResolvedValue({
    status: "error",
    error: "the bridge closed",
  });

  const host = mount(<SettingsPage />);
  await settle();

  const alert = host.querySelector('[role="alert"]');
  expect(alert?.textContent).toContain("the bridge closed");
  expect(alert?.textContent).toContain("unavailable");
});
