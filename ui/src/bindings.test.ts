// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import { commands } from "@/bindings";
import { NO_REASON_GIVEN } from "@/lib/settled";

// The seam every command answers through. The transport rejects with an
// `Error` when it fails rather than when the command refuses, and the runtime
// tauri-specta ships rethrows that — so the write paths that fire their
// command and forget it dropped the rejection: the busy flag fell and nothing
// was said. `typedError` is replaced at generation time (`specta_builder` in
// `crates/app/src/lib.rs`) to fold the rejection into the refusal shape
// instead, and this is what holds the replacement in place. Regenerate with
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
