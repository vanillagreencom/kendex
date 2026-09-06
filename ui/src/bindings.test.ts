// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import { commands, type Manifest_Deserialize } from "@/bindings";
import { NO_REASON_GIVEN } from "@/lib/settled";

// The seam every `Result`-returning command answers through — tauri-specta
// emits the runtime only where there is a refusal type to name, so
// `deep_link_take`, the one command still answering a plain value, rejects to
// its caller and is read through `caught` there. The transport
// rejects with an `Error` when it fails rather than when the command
// refuses, and the runtime tauri-specta ships rethrows that — so a write
// path that fires its command and forgets it would drop the rejection: the
// busy flag falls and nothing is said. `typedError` is replaced at
// generation time (`specta_builder` in `crates/app/src/lib.rs`) to fold the
// rejection into the refusal shape instead, and this is what holds the
// replacement in place. The fold puts a bare message where a shaped refusal
// is declared, which the signature admits as `E | string`: that is what makes
// `tsc` name a reader branching on a discriminant the runtime does not
// guarantee. Regenerate with
// `cargo test -p kendex-app -- --ignored regenerate_bindings`.
//
// Driven through the transport the app really has — the bridge Tauri reads
// off the window — rather than a mocked module: no UI file may import
// `@tauri-apps` but the generated bindings, and nothing else reaches the
// generated runtime, because every store test stubs `commands` above it.
type Bridge = { invoke: (cmd: string, args: unknown) => Promise<unknown> };
const bridged = window as unknown as { __TAURI_INTERNALS__?: Bridge };

/** The bridge answering every command with this rejection. */
function rejectingWith(thrown: unknown): void {
  bridged.__TAURI_INTERNALS__ = { invoke: () => Promise.reject(thrown) };
}

describe("a command whose transport rejected", () => {
  beforeEach(() => {
    delete bridged.__TAURI_INTERNALS__;
  });

  it("answers with the refusal shape and the rejection's message", async () => {
    rejectingWith(new Error("the channel is gone"));

    await expect(commands.scanMachine()).resolves.toEqual({
      status: "error",
      error: "the channel is gone",
    });
  });

  // A blank message renders as blank under whatever title shows it, and a
  // caller testing it by truthiness reads the failure as no failure — the
  // same silence the fold exists to end. `lib/settled.ts` owns the words,
  // and this holds the generated copy of them to it.
  it("stands words in for a rejection that says nothing", async () => {
    rejectingWith(new Error(""));

    await expect(commands.scanMachine()).resolves.toEqual({
      status: "error",
      error: NO_REASON_GIVEN,
    });
  });

  // The engine's own refusal arrives as the rejected value itself, never as
  // an `Error`, and it must keep the shape its type promises.
  it("passes an engine refusal through as the value it rejected with", async () => {
    rejectingWith({ kind: "stale" });

    await expect(
      commands.saveCustomize({ scope: "global" }, null, null),
    ).resolves.toEqual({ status: "error", error: { kind: "stale" } });
  });
});

// The other half of the same runtime: folding a failure is only right if a
// command that works still answers what it returned. Without this a runtime
// that broke the `ok` arm would pass the file that exists to hold it honest.
describe("a command whose transport answered", () => {
  beforeEach(() => {
    delete bridged.__TAURI_INTERNALS__;
  });

  it("answers with the value the command returned", async () => {
    const returned = { harnesses: ["claude"] };
    bridged.__TAURI_INTERNALS__ = {
      invoke: () => Promise.resolve(returned),
    };

    await expect(commands.scanMachine()).resolves.toEqual({
      status: "ok",
      data: returned,
    });
  });

  it.each<Manifest_Deserialize>([
    { schema: 6 },
    {
      schema: 6,
      "bot-instructions": {
        schema: 1,
        bots: { codex: true, qodo: false },
        cadence: { qodo_commands: ["/review"] },
        doctrine: { append: { severity: "Keep the repo rule." } },
      },
    },
  ])(
    "retains optional bot settings through the manifest bridge: %j",
    async (manifest) => {
      const returned = { manifest };
      bridged.__TAURI_INTERNALS__ = {
        invoke: () => Promise.resolve(returned),
      };
      await expect(commands.getManifest({ scope: "global" })).resolves.toEqual({
        status: "ok",
        data: returned,
      });
      let sent: unknown;
      bridged.__TAURI_INTERNALS__ = {
        invoke: (_command, args) => {
          sent = args;
          return Promise.resolve({});
        },
      };
      await commands.saveCustomize(
        { scope: "global" },
        { manifest, base: null },
        null,
      );
      expect(sent).toEqual({
        scope: { scope: "global" },
        manifest: { manifest, base: null },
        settings: null,
      });
    },
  );
});
