import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AppSettings } from "@/bindings";
import { commands } from "@/bindings";
import { useProblemsStore } from "./problems";
import { useScanStore } from "./scan";
import { useSettingsStore } from "./settings";
import { projectsOf } from "./settings-projects";

vi.mock("@/bindings", () => ({
  commands: {
    getSettings: vi.fn(),
    capabilityTable: vi.fn(),
    updateSettings: vi.fn(),
    registerProject: vi.fn(),
    unregisterProject: vi.fn(),
    discoverProjects: vi.fn(),
    scanMachine: vi.fn(),
    // Registering or dropping a project re-audits: the scopes changed.
    auditAll: vi.fn(),
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    windowSetZoom: vi.fn(),
    windowZoomState: vi.fn(),
    saveZoom: vi.fn(),
  },
  ZOOM: { min: 50, max: 200, step: 10, default: 100 },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn() },
}));

const settings: AppSettings = {
  schema: 1,
  appearance: "system",
  "harness-roots": {},
  projects: [],
  zoom: 100,
};

describe("settings store", () => {
  beforeEach(() => {
    useSettingsStore.setState({ settings: null, base: null, capabilities: [] });
    useScanStore.setState({
      result: null,
      scanning: false,
      error: null,
      lastScanAt: null,
      backgroundFailureAnnounced: false,
    });
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.clearAllMocks();
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.windowZoomState).mockResolvedValue({
      percent: settings.zoom ?? 100,
      launchRefused: false,
    });
  });

  it("shows the error modal with the backend message and leaves settings untouched when a save fails", async () => {
    useSettingsStore.setState({ settings });
    vi.mocked(commands.updateSettings).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: "disk is full" },
    });

    await useSettingsStore.getState().setAppearance("dark");

    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.title).toBe("Couldn't change the appearance");
    expect(dialog.message).toBe("disk is full");
    expect(useSettingsStore.getState().settings).toBe(settings);
  });

  /// A transport failure folds into the refusal's place as the message
  /// alone, which is neither arm of `WriteRefused`. Read by `kind` it misses
  /// `failed`, falls to the stale-recovery arm, and reports a broken pipe as
  /// the settings having changed in another window — while spending a
  /// `getSettings` read to say it.
  it("shows the message when the transport failed rather than the engine refusing", async () => {
    useSettingsStore.setState({ settings });
    vi.mocked(commands.updateSettings).mockResolvedValue({
      status: "error",
      error: "the channel is gone",
    } as Awaited<ReturnType<typeof commands.updateSettings>>);

    await useSettingsStore.getState().setAppearance("dark");

    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.message).toBe("the channel is gone");
    expect(commands.getSettings).not.toHaveBeenCalled();
    expect(useSettingsStore.getState().settings).toBe(settings);
  });

  it("saves settings silently on success — no toast, no modal for an instant, visible change", async () => {
    const updated = { ...settings, appearance: "dark" as const };
    useSettingsStore.setState({ settings });
    vi.mocked(commands.updateSettings).mockResolvedValue({
      status: "ok",
      data: { settings: updated, base: "b1" },
    });

    await useSettingsStore.getState().setAppearance("dark");

    expect(toast.success).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.open).toBe(false);
    expect(useSettingsStore.getState().settings).toEqual(updated);
  });

  /// The refusal that closes the class: a copy read before something else
  /// wrote the file is never applied. The change is a field-level intent,
  /// so it is carried onto a freshly read copy and written again — nothing
  /// the stale copy predated is reverted, and the person sees no error.
  it("re-reads and re-applies the change when the copy in hand is stale", async () => {
    useSettingsStore.setState({ settings, base: "old" });
    const onDisk = { ...settings, projects: ["/home/x/acme-web"], zoom: 150 };
    vi.mocked(commands.updateSettings)
      .mockResolvedValueOnce({ status: "error", error: { kind: "stale" } })
      .mockImplementationOnce(async (next) => ({
        status: "ok",
        data: { settings: next, base: "written" },
      }));
    vi.mocked(commands.getSettings).mockResolvedValue({
      status: "ok",
      data: { settings: onDisk, base: "fresh" },
    });

    await useSettingsStore.getState().setAppearance("dark");

    // The second write carried the fresh copy — project and zoom kept —
    // with only the intended field changed, under the fresh base.
    expect(commands.updateSettings).toHaveBeenLastCalledWith(
      { ...onDisk, appearance: "dark" },
      "fresh",
    );
    expect(useProblemsStore.getState().dialog.open).toBe(false);
    expect(useSettingsStore.getState().settings).toEqual({
      ...onDisk,
      appearance: "dark",
    });
    expect(useSettingsStore.getState().base).toBe("written");
  });

  /// The re-read is the way out of a stale refusal; when it fails, the
  /// dialog names the failed read — not contention, which would claim a
  /// refresh that never happened and invite retries of a path that
  /// cannot progress.
  it("names the failed re-read when stale recovery cannot read the settings", async () => {
    useSettingsStore.setState({ settings, base: "old" });
    vi.mocked(commands.updateSettings).mockResolvedValue({
      status: "error",
      error: { kind: "stale" },
    });
    vi.mocked(commands.getSettings).mockResolvedValue({
      status: "error",
      error: "cannot read the settings file",
    });

    await useSettingsStore.getState().setAppearance("dark");

    expect(commands.updateSettings).toHaveBeenCalledTimes(1);
    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.message).toContain("cannot read the settings file");
    expect(dialog.message).not.toContain("another window");
    // The store still holds the copy it had — nothing pretended to refresh.
    expect(useSettingsStore.getState().settings).toBe(settings);
    expect(useSettingsStore.getState().base).toBe("old");
  });

  /// Contention that survives the re-read reaches the person as a message,
  /// not as a silent loop — and never as a write of the stale copy. The
  /// claim that the latest settings are shown is earned by one final
  /// read-only refresh, because the second refusal proved the previous
  /// re-read is already behind the file.
  it("stops after one retry, refreshes read-only, and tells the person when the file keeps moving", async () => {
    useSettingsStore.setState({ settings, base: "old" });
    const moved = { ...settings, zoom: 150 };
    vi.mocked(commands.updateSettings).mockResolvedValue({
      status: "error",
      error: { kind: "stale" },
    });
    vi.mocked(commands.getSettings)
      .mockResolvedValueOnce({
        status: "ok",
        data: { settings, base: "fresh" },
      })
      .mockResolvedValueOnce({
        status: "ok",
        data: { settings: moved, base: "moved" },
      });

    await useSettingsStore.getState().setAppearance("dark");

    expect(commands.updateSettings).toHaveBeenCalledTimes(2);
    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.title).toBe("Couldn't change the appearance");
    expect(dialog.message).toContain("the latest settings are shown now");
    // The store holds what the final refresh read, not the copy the second
    // write was refused over — that is what makes the claim true.
    expect(useSettingsStore.getState().settings).toEqual(moved);
    expect(useSettingsStore.getState().base).toBe("moved");
  });

  /// When the final refresh cannot be read, the message stops claiming the
  /// displayed settings are current — a claim nothing verified.
  it("drops the currency claim when the final refresh fails after a second stale refusal", async () => {
    useSettingsStore.setState({ settings, base: "old" });
    vi.mocked(commands.updateSettings).mockResolvedValue({
      status: "error",
      error: { kind: "stale" },
    });
    vi.mocked(commands.getSettings)
      .mockResolvedValueOnce({
        status: "ok",
        data: { settings, base: "fresh" },
      })
      .mockResolvedValueOnce({
        status: "error",
        error: "cannot read the settings file",
      });

    await useSettingsStore.getState().setAppearance("dark");

    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.message).not.toContain("shown now");
    expect(dialog.message).toContain("cannot read the settings file");
  });

  /// The backend serializes the writes, but replies arrive in any order:
  /// a whole-file save resolving after a later project registration must
  /// not put its older settings/base pair back over the newer one.
  it("drops a reply that arrives after a newer one was held", async () => {
    useSettingsStore.setState({ settings, base: "b0" });
    let resolveUpdate: (value: {
      status: "ok";
      data: { settings: AppSettings; base: string };
    }) => void = () => {};
    vi.mocked(commands.updateSettings).mockReturnValue(
      new Promise((resolve) => {
        resolveUpdate = resolve;
      }),
    );
    const registered = { ...settings, projects: ["/home/x/acme-web"] };
    vi.mocked(commands.registerProject).mockResolvedValue({
      status: "ok",
      data: { settings: registered, base: "b2" },
    });

    const older = useSettingsStore.getState().setAppearance("dark");
    await useSettingsStore.getState().registerProject("/home/x/acme-web");
    resolveUpdate({
      status: "ok",
      data: { settings: { ...settings, appearance: "dark" }, base: "b1" },
    });
    await older;

    expect(useSettingsStore.getState().base).toBe("b2");
    expect(useSettingsStore.getState().settings).toEqual(registered);
  });

  it("toasts success naming the folder when a project is added, and resolves true", async () => {
    vi.mocked(commands.registerProject).mockResolvedValue({
      status: "ok",
      data: {
        settings: { ...settings, projects: ["/home/x/acme-web"] },
        base: "b1",
      },
    });

    const ok = await useSettingsStore
      .getState()
      .registerProject("/home/x/acme-web");

    expect(ok).toBe(true);
    // The success toast also offers the session drift report — an offer at
    // registration, never an auto-install.
    expect(toast.success).toHaveBeenCalledWith(
      "Added acme-web",
      expect.objectContaining({
        action: expect.objectContaining({ label: "Add session drift report" }),
      }),
    );
  });

  it("shows the error modal and resolves false when adding a project fails, without touching settings", async () => {
    useSettingsStore.setState({ settings });
    vi.mocked(commands.registerProject).mockResolvedValue({
      status: "error",
      error: "project already registered: /home/x/acme-web",
    });

    const ok = await useSettingsStore
      .getState()
      .registerProject("/home/x/acme-web");

    expect(ok).toBe(false);
    expect(toast.success).not.toHaveBeenCalled();
    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.title).toBe("Couldn't add the project");
    expect(dialog.message).toBe("project already registered: /home/x/acme-web");
    expect(useSettingsStore.getState().settings).toBe(settings);
  });

  it("shows the error modal without a success toast when removing a project fails", async () => {
    useSettingsStore.setState({ settings });
    vi.mocked(commands.unregisterProject).mockResolvedValue({
      status: "error",
      error: "project not registered: /home/x/gone",
    });

    await useSettingsStore.getState().unregisterProject("/home/x/gone");

    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.title).toBe("Couldn't stop tracking the project");
    expect(dialog.message).toBe("project not registered: /home/x/gone");
    expect(toast.success).not.toHaveBeenCalled();
  });

  it("shows the error modal on a failed load instead of storing a buried error", async () => {
    vi.mocked(commands.getSettings).mockResolvedValue({
      status: "error",
      error: "cannot locate the home directory on this system",
    });
    vi.mocked(commands.capabilityTable).mockResolvedValue([]);

    await useSettingsStore.getState().load();

    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.title).toBe("Couldn't load your settings");
    expect(dialog.message).toBe(
      "cannot locate the home directory on this system",
    );
    expect(useSettingsStore.getState().settings).toBeNull();
  });

  it("shows the error modal and returns an empty list when discovering projects fails", async () => {
    vi.mocked(commands.discoverProjects).mockResolvedValue({
      status: "error",
      error: "/nope is not a directory",
    });

    const found = await useSettingsStore.getState().discoverProjects("/nope");

    expect(found).toEqual([]);
    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.title).toBe("Couldn't search that folder");
    expect(dialog.message).toBe("/nope is not a directory");
  });
});

// A React store selector is read on every render, and a value it mints
// fresh each time is a store that never stops changing. What that does to a
// mounted tree is settings-projects.dom.test.tsx; this is the identity
// itself.
describe("the projects selector", () => {
  it("answers with one and the same empty list until the read lands", () => {
    expect(projectsOf({ settings: null })).toBe(projectsOf({ settings: null }));
  });
});
