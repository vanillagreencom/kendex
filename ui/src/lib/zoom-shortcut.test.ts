import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ZOOM } from "@/bindings";
import { ZOOM_SETTLE_MS, zoomForKey, zoomGesture } from "./zoom-shortcut";

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

describe("zoomGesture", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("resizes on every press and writes once the presses stop", () => {
    const preview = vi.fn();
    const save = vi.fn();
    const gesture = zoomGesture(preview, save);

    expect(gesture(press("+"), 100)).toBe(true);
    vi.advanceTimersByTime(ZOOM_SETTLE_MS - 1);
    expect(gesture(press("+"), 110)).toBe(true);
    vi.advanceTimersByTime(ZOOM_SETTLE_MS - 1);
    expect(gesture(press("+"), 120)).toBe(true);

    // A held key repeats faster than the size is written.
    expect(preview).toHaveBeenCalledTimes(3);
    expect(save).not.toHaveBeenCalled();

    vi.advanceTimersByTime(ZOOM_SETTLE_MS);
    expect(save).toHaveBeenCalledTimes(1);
  });

  it("leaves a press that means something else alone", () => {
    const preview = vi.fn();
    const save = vi.fn();
    const gesture = zoomGesture(preview, save);

    expect(gesture(press("a"), 100)).toBe(false);
    vi.advanceTimersByTime(ZOOM_SETTLE_MS * 2);
    expect(preview).not.toHaveBeenCalled();
    expect(save).not.toHaveBeenCalled();
  });
});
