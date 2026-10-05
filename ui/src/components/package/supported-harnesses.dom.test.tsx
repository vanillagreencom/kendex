// @vitest-environment jsdom
// The row says what core answered in the words of `kendex show`'s
// `supported tools:` line: each line here is one shape that answer takes,
// read back as the lead and the harness chips with their reasons.
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import type { HarnessId } from "@/bindings";
import {
  SUPPORTED_ADVISORY_ON,
  SUPPORTED_ALL,
  SUPPORTED_ALL_EXCEPT,
  SUPPORTED_FALLBACK_ON,
  SUPPORTED_NONE,
} from "@/lib/copy-library";
import { harnessName } from "@/lib/labels";
import { useNavStore } from "@/stores/nav";
import { mount } from "@/test/dom";
import { type HarnessSupport, SupportedHarnesses } from "./supported-harnesses";

const EVERY: HarnessId[] = [
  "claude",
  "codex",
  "opencode",
  "cursor",
  "pi",
  "gemini",
  "copilot",
  "antigravity",
];

const support = (part: Partial<HarnessSupport>): HarnessSupport => ({
  unsupported: [],
  advisory: [],
  fallback: [],
  ...part,
});

/** Each line as `lead: item; item`, an item being its chip's name and the
 *  reason beside it. */
const lines = (host: HTMLElement): string[] =>
  [...(host.firstElementChild?.children ?? [])].map((line) => {
    const lead = line.firstElementChild?.textContent ?? "";
    const items = [...line.querySelectorAll("li")].map((item) =>
      [...item.childNodes].map((part) => part.textContent).join(" "),
    );
    return items.length > 0 ? `${lead}: ${items.join("; ")}` : lead;
  });

describe("the supported harnesses row", () => {
  const rows: [string, HarnessSupport, string[]][] = [
    ["every harness", support({}), [SUPPORTED_ALL]],
    [
      "unsupported, with and without a reason",
      support({
        unsupported: [
          { tool: "pi", reason: "it has no Stop event" },
          { tool: "gemini", reason: null },
        ],
      }),
      [
        `${SUPPORTED_ALL_EXCEPT}: ${harnessName("pi")} it has no Stop event; ${harnessName("gemini")}`,
      ],
    ],
    [
      "advisory on the harnesses that run no hooks",
      support({ advisory: ["opencode", "cursor"] }),
      [
        SUPPORTED_ALL,
        `${SUPPORTED_ADVISORY_ON}: ${harnessName("opencode")}; ${harnessName("cursor")}`,
      ],
    ],
    [
      "a fallback, with its reason",
      support({
        unsupported: [{ tool: "gemini", reason: null }],
        advisory: ["cursor"],
        fallback: [{ tool: "codex", reason: "a watcher reads its pane" }],
      }),
      [
        `${SUPPORTED_ALL_EXCEPT}: ${harnessName("gemini")}`,
        `${SUPPORTED_ADVISORY_ON}: ${harnessName("cursor")}`,
        `${SUPPORTED_FALLBACK_ON}: ${harnessName("codex")} a watcher reads its pane`,
      ],
    ],
    [
      "no harness, without a reason",
      support({
        unsupported: EVERY.map((tool) => ({ tool, reason: null })),
      }),
      [SUPPORTED_NONE],
    ],
    [
      "no harness, the shared reason said once",
      support({
        unsupported: EVERY.map((tool) => ({
          tool,
          reason: "its script could not be read",
        })),
      }),
      [`${SUPPORTED_NONE}: its script could not be read`],
    ],
  ];

  for (const [name, given, expected] of rows) {
    it(name, () => {
      const host = mount(<SupportedHarnesses support={given} />);
      expect(lines(host)).toEqual(expected);
    });
  }

  it("opens the harness a chip names", async () => {
    const goToLibrary = useNavStore.getState().goToLibrary;
    const opened: unknown[] = [];
    useNavStore.setState({
      page: "package",
      goToLibrary: (handoff) => opened.push(handoff),
    });
    try {
      const host = mount(
        <SupportedHarnesses
          support={support({ unsupported: [{ tool: "pi", reason: null }] })}
        />,
      );
      const chip = host.querySelector<HTMLButtonElement>(
        `button[aria-label="${harnessName("pi")}"]`,
      );
      if (!chip) throw new Error("no chip for pi");
      await userEvent.click(chip);
      expect(opened).toEqual([{ harness: "pi" }]);
    } finally {
      useNavStore.setState({ goToLibrary });
    }
  });
});
