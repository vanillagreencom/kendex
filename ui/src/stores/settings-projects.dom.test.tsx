// @vitest-environment jsdom
// A selector that mints a fresh array per snapshot is a store React reads
// as changed on every render: the tree holding it re-renders until React
// throws, and with no error boundary anywhere in `ui/src` the window goes
// blank. Nothing but a mount can see that. The subscribe dialog and the
// Customize page are mounted here with the settings read unlanded, which is
// the state the app first draws each of them in.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { SubscribeDialog } from "@/components/marketplaces/subscribe-dialog";
import { CustomizePage } from "@/pages/customize";
import { useEditorStore } from "@/stores/editor";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useSettingsStore } from "@/stores/settings";
import { mount, settle } from "@/test/dom";

vi.mock("@/bindings", () => ({
  MANIFEST_SCHEMA: 6,
  commands: {
    getManifest: vi.fn(),
    getScopeSettings: vi.fn(),
    editorInventory: vi.fn(),
  },
}));
vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), message: vi.fn() },
}));

beforeEach(() => {
  vi.clearAllMocks();
  // The Customize page reads its draft on mount. Nothing here is about what
  // it finds, only that the tree settles.
  vi.mocked(commands.getManifest).mockResolvedValue({
    status: "ok",
    data: { manifest: null, base: null },
  } as never);
  vi.mocked(commands.getScopeSettings).mockResolvedValue({
    status: "ok",
    data: null,
  } as never);
  vi.mocked(commands.editorInventory).mockResolvedValue({
    status: "ok",
    data: { skills: [], hooks: [] },
  } as never);
  useSettingsStore.setState({ settings: null });
  useMarketplacesStore.setState({ busy: false, error: null });
  useEditorStore.setState({ draft: null, dirty: false, loading: false });
});

describe("a surface drawn before the settings read lands", () => {
  it("mounts the Marketplaces page's subscribe dialog", async () => {
    const host = mount(<SubscribeDialog open onOpenChange={() => {}} />);
    await settle();

    expect(host.ownerDocument.body.textContent).toContain("Personal");
  });

  it("mounts the Customize page", async () => {
    const host = mount(<CustomizePage />);
    await settle();

    expect(host.textContent).toContain("Customize");
  });
});
