import { describe, expect, it } from "vitest";
import { ZOOM } from "@/bindings";
import { zoomForKey } from "./zoom-shortcut";

const press = (key: string, extra: Record<string, boolean> = {}) => ({
  key,
  ctrlKey: true,
  metaKey: false,
  altKey: false,
  ...extra,
});

describe("zoomForKey", () => {
  it("steps in and out, and resets to full size", () => {
    expect(zoomForKey(press("+"), 100)).toBe(100 + ZOOM.step);
    expect(zoomForKey(press("="), 100)).toBe(100 + ZOOM.step);
    expect(zoomForKey(press("-"), 100)).toBe(100 - ZOOM.step);
    expect(zoomForKey(press("_"), 100)).toBe(100 - ZOOM.step);
    expect(zoomForKey(press("0"), 175)).toBe(ZOOM.default);
  });

  it("stops at the ends of the range instead of running past them", () => {
    expect(zoomForKey(press("+"), ZOOM.max)).toBe(ZOOM.max);
    expect(zoomForKey(press("-"), ZOOM.min)).toBe(ZOOM.min);
  });

  it("takes Cmd as well as Ctrl", () => {
    expect(zoomForKey(press("+", { ctrlKey: false, metaKey: true }), 100)).toBe(
      100 + ZOOM.step,
    );
  });

  it("leaves every other press alone", () => {
    expect(zoomForKey(press("+", { ctrlKey: false }), 100)).toBeNull();
    expect(zoomForKey(press("+", { altKey: true }), 100)).toBeNull();
    expect(zoomForKey(press("a"), 100)).toBeNull();
    expect(zoomForKey(press("1"), 100)).toBeNull();
  });
});
