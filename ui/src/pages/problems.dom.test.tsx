// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AuditView,
  DriftRow,
  RowExits,
  ScanWarning,
  Scope,
} from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { AUDIT_ATTENTION_TITLE, COPY_PATH_LABEL } from "@/lib/copy";
import {
  KEEP_FILES_LABEL,
  MANAGE_CONFIRM_BODY,
  MOVE_FILES_YOURSELF,
  manageConfirmTitle,
  PROCEED_LABEL,
  REPLACE_FILES_CONFIRM_LABEL,
  REPLACE_FILES_LABEL,
} from "@/lib/copy-in-the-way";
import { PROBLEMS_EMPTY, PROBLEMS_NOTES_TITLE } from "@/lib/error-copy";
import { READ_LANDED, readFailed } from "@/lib/read-state";
import { useAuditStore } from "@/stores/audit";
import { useScanStore } from "@/stores/scan";
import { mount, settle } from "@/test/dom";
import { ProblemsPage } from "./problems";

vi.mock("@/bindings", () => ({
  commands: {
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    auditAll: vi.fn(),
    scanMachine: vi.fn(),
    adoptItem: vi.fn(),
    replaceUnmanagedItem: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const ACME: Scope = { scope: "project", root: "/work/acme" };
const PERSONAL: Scope = { scope: "global" };

const inTheWay = (
  name: string,
  harness: DriftRow["harness"],
  over: Partial<DriftRow> = {},
): DriftRow => ({
  kind: "skill",
  name,
  harness,
  scope: ACME,
  state: "conflict",
  cause: "unmanaged-content",
  detail: `/work/acme/.${harness}/skills/${name}`,
  ...over,
});

const exit = (key: string, over: Partial<RowExits> = {}): RowExits => ({
  key,
  blocking: true,
  files: true,
  keep: true,
  enter: true,
  replace: true,
  tools: [key.split(":")[2] as RowExits["tools"][number]],
  ...over,
});

const view = (over: Partial<AuditView>): AuditView => ({
  scope: ACME,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits: [],
  ...over,
});

/** One ordinary blocked item, staged at whichever place is named. */
const oneBlocked = (scope: Scope, name: string): AuditView =>
  view({
    scope,
    drift: [{ ...inTheWay(name, "claude"), scope }],
    exits: [exit(`skill:${name}:claude`)],
  });

const stage = (views: AuditView[], failure: string | null = null) =>
  act(() => {
    useAuditStore.setState({
      views,
      auditedAt: Date.now(),
      read: failure === null ? READ_LANDED : readFailed(failure),
      busy: false,
    });
  });

const button = (host: HTMLElement, label: string) =>
  [...host.querySelectorAll("button")].find(
    (el) => el.textContent?.trim() === label,
  );

// The row's Replace button and the dialog's confirm carry the same words,
// so a search over the whole document would press the row again.
const dialog = () => {
  const el = document.body.querySelector('[role="dialog"]');
  expect(el).not.toBeNull();
  return el as HTMLElement;
};

const press = async (el: Element | undefined) => {
  expect(el).toBeDefined();
  await act(async () => {
    (el as HTMLButtonElement).click();
  });
};

const cards = (host: HTMLElement) => [
  ...host.querySelectorAll("[data-slot='card']"),
];

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: { items: [], harnesses: [], warnings: [], missingProjects: [] },
  } as never);
  vi.mocked(commands.adoptItem).mockResolvedValue({
    status: "ok",
    data: view({}),
  } as never);
  vi.mocked(commands.replaceUnmanagedItem).mockResolvedValue({
    status: "ok",
    data: view({}),
  } as never);
  useAuditStore.setState({
    views: [],
    auditedAt: null,
    read: READ_LANDED,
    busy: false,
  });
});

describe("a declared item whose place already holds files", () => {
  const offers = [
    {
      name: "offers only the exits core reported for the row",
      item: "scout",
      reading: view({
        drift: [
          inTheWay("scout", "claude", { cause: "unmanaged-wrong-shape" }),
        ],
        exits: [exit("skill:scout:claude", { keep: false, enter: true })],
      }),
      keep: false,
      replace: true,
      manual: true,
    },
    {
      name: "offers keeping alone where core refuses the replacement",
      item: "browser",
      reading: view({
        drift: [inTheWay("browser", "claude", { cause: "shared-link" })],
        exits: [exit("skill:browser:claude", { replace: false })],
      }),
      keep: true,
      replace: false,
      manual: false,
    },
    {
      name: "offers neither exit when one installation refuses it",
      item: "release-notes",
      reading: view({
        drift: [
          inTheWay("release-notes", "claude"),
          inTheWay("release-notes", "codex"),
        ],
        exits: [
          exit("skill:release-notes:claude"),
          exit("skill:release-notes:codex", {
            keep: false,
            enter: false,
            replace: false,
            tools: ["codex"],
          }),
        ],
      }),
      keep: false,
      replace: false,
      manual: true,
    },
  ];
  expect(offers).toHaveLength(3);
  it.each(offers)("$name", async (row) => {
    stage([row.reading]);
    const host = mount(<ProblemsPage />);
    await settle();
    expect(
      {
        item: host.textContent?.includes(row.item),
        keep: button(host, KEEP_FILES_LABEL) !== undefined,
        replace: button(host, REPLACE_FILES_LABEL) !== undefined,
        manual: host.textContent?.includes(MOVE_FILES_YOURSELF),
      },
      row.name,
    ).toEqual({
      item: true,
      keep: row.keep,
      replace: row.replace,
      manual: row.manual,
    });
  });

  it("takes the item over through replaceUnmanagedItem", async () => {
    stage([oneBlocked(ACME, "release-notes")]);
    const host = mount(<ProblemsPage />);
    await settle();

    await press(button(host, REPLACE_FILES_LABEL));
    // The dialog renders into a portal, so the confirm is off the page's
    // own tree.
    await press(button(dialog(), REPLACE_FILES_CONFIRM_LABEL));

    expect(commands.replaceUnmanagedItem).toHaveBeenCalledWith(
      ACME,
      "skill",
      "release-notes",
    );
  });

  // A tree read through a harness-native link has a second position of the
  // reader's own files. Core names it on the row; the confirm has to say
  // it, or the take-over moves a directory the dialog never showed.
  it("names every position core says the take-over empties", async () => {
    stage([
      view({
        drift: [
          inTheWay("deploy", "claude", {
            detail: "/work/acme/.agents/skills/deploy",
            alsoInTheWay: ["/work/acme/.claude/skills/deploy"],
          }),
        ],
        exits: [exit("skill:deploy:claude")],
      }),
    ]);
    const host = mount(<ProblemsPage />);
    await settle();

    await press(button(host, REPLACE_FILES_LABEL));
    const said = dialog().textContent ?? "";
    expect(said).toContain("/work/acme/.agents/skills/deploy");
    expect(said).toContain("/work/acme/.claude/skills/deploy");
  });

  // Two harnesses under the linking method: each refuses at its own
  // canonical with its own link beside it. Three positions is the ordinary
  // count once core reports the full set, and the confirm is the last
  // thing read before every one of them moves.
  it("lists every position rather than collapsing them to a number", async () => {
    const places = [
      "/work/acme/.agents/skills/deploy",
      "/work/acme/.claude/skills/deploy",
      "/work/acme/.codex/skills/deploy",
    ];
    stage([
      view({
        drift: [
          inTheWay("deploy", "claude", {
            detail: places[0],
            alsoInTheWay: [places[1]],
          }),
          inTheWay("deploy", "codex", {
            detail: places[0],
            alsoInTheWay: [places[2]],
          }),
        ],
        exits: [exit("skill:deploy:claude"), exit("skill:deploy:codex")],
      }),
    ]);
    const host = mount(<ProblemsPage />);
    await settle();

    await press(button(host, REPLACE_FILES_LABEL));
    const said = dialog().textContent ?? "";
    expect(places).toHaveLength(3);
    for (const place of places) expect(said).toContain(place);
    expect(said).not.toContain("3 places");
  });

  // A blocking row core reported no files for carries prose written for a
  // reader, not a path. Joined to a real path it reads as a second file
  // location, and moving files settles nothing it names.
  it("states a reason of another kind instead of spelling it as a path", async () => {
    const why =
      "/work/acme/.claude/skills/x cannot be compared (permission denied)";
    stage([
      view({
        drift: [
          inTheWay("deploy", "claude"),
          inTheWay("deploy", "codex", { cause: undefined, detail: why }),
        ],
        exits: [
          exit("skill:deploy:claude"),
          exit("skill:deploy:codex", {
            files: false,
            keep: false,
            enter: false,
            replace: false,
          }),
        ],
      }),
    ]);
    const host = mount(<ProblemsPage />);
    await settle();

    // The row's own path line, the only one carrying every position in
    // its title.
    const path = host.querySelector("span[title]");
    expect(path?.textContent).toBe("/work/acme/.claude/skills/deploy");
    expect(path?.getAttribute("title")).not.toContain("cannot be compared");
    expect(host.textContent).toContain(why);
    expect(host.textContent).not.toContain(MOVE_FILES_YOURSELF);
  });

  // A tool reading the folder through a shortcut somebody made has no row
  // of its own. Core names it, so the offer names it: keeping repoints
  // every link at that folder.
  it("names a tool core reports that has no row of its own", async () => {
    stage([
      view({
        drift: [inTheWay("browser", "claude", { cause: "shared-link" })],
        exits: [
          exit("skill:browser:claude", {
            replace: false,
            tools: ["claude", "codex"],
          }),
        ],
      }),
    ]);
    const host = mount(<ProblemsPage />);
    await settle();

    await press(button(host, KEEP_FILES_LABEL));
    expect(dialog().textContent).toContain("Claude Code and Codex");

    await press(button(dialog(), PROCEED_LABEL));
    expect(commands.adoptItem).toHaveBeenCalledWith(ACME, "skill", "browser", [
      "claude",
      "codex",
    ]);
  });

  // The heading is half of what the dialog says; one asking whether to
  // keep files would offer a choice the button under it does not run.
  it("heads the confirm with the action rather than with keeping files", async () => {
    stage([oneBlocked(ACME, "deploy")]);
    const host = mount(<ProblemsPage />);
    await settle();

    await press(button(host, KEEP_FILES_LABEL));
    const said = dialog().textContent ?? "";
    expect(said).toContain(manageConfirmTitle("deploy"));
    expect(said).not.toContain("Keep deploy's files?");
  });

  // The shared words answer for the shared installations alone: a group can
  // mix causes, and a summary over all of them is not a folder any tool
  // reads from.
  it("keeps the shared folder out of a plain keep's words", async () => {
    stage([
      view({
        drift: [inTheWay("deploy", "claude")],
        exits: [exit("skill:deploy:claude")],
      }),
    ]);
    const host = mount(<ProblemsPage />);
    await settle();

    await press(button(host, KEEP_FILES_LABEL));
    expect(dialog().textContent).toContain(MANAGE_CONFIRM_BODY);
    expect(dialog().textContent).not.toContain("read this skill from");
  });
});

describe("several places at once", () => {
  // Every card's buttons carry that card's own place into commands that
  // move files. Global and a project blocked together is ordinary.
  it("takes over at the place whose card was pressed", async () => {
    stage([oneBlocked(PERSONAL, "release-notes"), oneBlocked(ACME, "deploy")]);
    const host = mount(<ProblemsPage />);
    await settle();

    const second = cards(host)[1] as HTMLElement;
    await press(button(second, REPLACE_FILES_LABEL));
    await press(button(dialog(), REPLACE_FILES_CONFIRM_LABEL));

    expect(commands.replaceUnmanagedItem).toHaveBeenCalledWith(
      ACME,
      "skill",
      "deploy",
    );
  });
});

// Every button behind these rows moves the reader's own files, and a kept
// view still reads clean after a check that never answered.
describe("a check that failed", () => {
  it("draws no exits and says the reading is old", async () => {
    stage([oneBlocked(ACME, "release-notes")], "audit refused");
    const host = mount(<ProblemsPage />);
    await settle();

    expect(host.textContent).toContain(AUDIT_ATTENTION_TITLE);
    expect(host.textContent).not.toContain(PROBLEMS_EMPTY);
    expect(host.querySelectorAll("button")).toHaveLength(1);
  });

  // The control: the same views draw both exits once a check answers.
  it("draws them again once a check answers", async () => {
    stage([oneBlocked(ACME, "release-notes")]);
    const host = mount(<ProblemsPage />);
    await settle();

    expect(host.textContent).not.toContain(AUDIT_ATTENTION_TITLE);
    expect(button(host, REPLACE_FILES_LABEL)).toBeDefined();
  });
});

// A file the scan could not read gets a card of its own: whose it is,
// where, what is wrong and the buttons that get the reader to the fix.
// Nothing on the audit knows about it, so the page reads it off the scan.
describe("a file the scan could not read", () => {
  const stageScan = (warnings: ScanWarning[]) =>
    act(() => {
      useScanStore.setState({
        result: {
          harnesses: [],
          items: [],
          missingProjects: [],
          readProjects: [],
          warnings,
        },
        error: null,
      });
    });

  it("draws the card with the remedy and the path to copy", () => {
    stage([]);
    stageScan([
      {
        harness: "antigravity",
        kind: "mcp-server",
        path: "/h/.gemini/config/mcp_config.json",
        problem: { kind: "empty-file" },
        standing: "actionable",
      },
    ]);
    const host = mount(<ProblemsPage />);
    expect(cards(host)).toHaveLength(1);
    expect(host.textContent).toContain(
      "Antigravity's MCP servers file is empty",
    );
    expect(host.textContent).toContain("/h/.gemini/config/mcp_config.json");
    expect(host.textContent).toContain("Delete it, or put {} in it");
    expect(button(host, COPY_PATH_LABEL)).toBeDefined();
    expect(host.textContent).not.toContain(PROBLEMS_EMPTY);
    expect(host.textContent).not.toContain(PROBLEMS_NOTES_TITLE);
  });

  // The same file, in the same shape, with core's answer that nothing on
  // this machine asked for a server in it: said once under its own
  // heading, with no remedy and no button, and the page above it still
  // reports the machine clean.
  it("says an unused empty container is nothing to fix and asks for no repair", () => {
    stage([]);
    stageScan([
      {
        harness: "antigravity",
        kind: "mcp-server",
        path: "/h/.gemini/config/mcp_config.json",
        problem: { kind: "empty-file" },
        standing: "unused-empty-container",
      },
    ]);
    const host = mount(<ProblemsPage />);
    expect(host.textContent).toContain(PROBLEMS_NOTES_TITLE);
    expect(host.textContent).toContain(
      "Antigravity's MCP servers file is empty",
    );
    expect(host.textContent).toContain("/h/.gemini/config/mcp_config.json");
    expect(host.textContent).toContain(
      "kendex manages no MCP servers for Antigravity, so nothing is missing here.",
    );
    expect(host.textContent).toContain("does not change it");
    expect(host.textContent).not.toContain("Delete it, or put {} in it");
    expect(button(host, COPY_PATH_LABEL)).toBeUndefined();
    expect(host.textContent).toContain(PROBLEMS_EMPTY);
  });

  it("draws no card and reports no problems once the scan reads clean", () => {
    stage([]);
    stageScan([]);
    const host = mount(<ProblemsPage />);
    expect(cards(host)).toHaveLength(0);
    expect(host.textContent).toContain(PROBLEMS_EMPTY);
  });
});
