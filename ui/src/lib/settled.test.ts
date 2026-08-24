import { describe, expect, it } from "vitest";
import { NO_REASON_GIVEN, settled } from "./settled";

describe("settled", () => {
  it("passes a returned refusal through untouched", async () => {
    await expect(
      settled(Promise.resolve({ status: "error" as const, error: "refused" })),
    ).resolves.toEqual({ status: "error", error: "refused" });
  });

  it("lands a rejection as the same shape as a refusal", async () => {
    await expect(
      settled(Promise.reject(new Error("ipc down"))),
    ).resolves.toEqual({ status: "error", error: "ipc down" });
  });

  // An empty failure message renders as a blank error body — and reads as
  // no error at all to any consumer testing the message by truthiness —
  // whether it arrives as a thrown Error with no message or as a refusal
  // the engine returned with an empty reason.
  it("never lands an empty failure message", async () => {
    await expect(settled(Promise.reject(new Error()))).resolves.toEqual({
      status: "error",
      error: NO_REASON_GIVEN,
    });
    await expect(settled(Promise.reject(""))).resolves.toEqual({
      status: "error",
      error: NO_REASON_GIVEN,
    });
    await expect(
      settled(Promise.resolve({ status: "error" as const, error: "" })),
    ).resolves.toEqual({ status: "error", error: NO_REASON_GIVEN });
  });
});
