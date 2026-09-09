// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { SecretRow } from "@/bindings";
import {
  SECRET_CLEAR_ACTION,
  SECRET_NOT_SET,
  SECRET_REPLACE_ACTION,
  SECRET_REQUIRED,
  SECRET_SET,
  SECRET_SET_ACTION,
  SECRET_SET_NOTE,
  SECRET_UNKNOWN,
  secretFieldHelp,
} from "@/lib/copy-customize";
import { mount } from "@/test/dom";
import { SecretFieldRow } from "./secret-field-row";

const row = (over: Partial<SecretRow> = {}): SecretRow => ({
  key: "LINEAR_API_KEY",
  explainer: ["The key every call authenticates with."],
  required: true,
  current: { state: "not-set" },
  ...over,
});

const render = (
  over: Partial<SecretRow> = {},
  props: Partial<Parameters<typeof SecretFieldRow>[0]> = {},
) =>
  mount(
    <SecretFieldRow
      skill="linear"
      row={row(over)}
      file=".env.local"
      writable
      onEdit={() => {}}
      onCancel={() => {}}
      {...props}
    />,
  );

const button = (host: HTMLElement, label: string) =>
  [...host.querySelectorAll("button")].find(
    (one) => one.textContent === label,
  ) ?? null;

describe("SecretFieldRow", () => {
  /// Three answers, each said in words. Not set and can't check are
  /// different facts: a person told a key is missing sets it again, over
  /// whatever is there.
  it("says which of the three states the key is in", () => {
    expect(render().textContent).toContain(SECRET_NOT_SET);
    expect(render({ current: { state: "set" } }).textContent).toContain(
      SECRET_SET,
    );
    expect(
      render({ current: { state: "unknown", reason: "assigned twice" } })
        .textContent,
    ).toContain(SECRET_UNKNOWN);
  });

  /// A stored value says somebody typed one and nothing more. Saying the
  /// package is connected would claim kendex asked the provider, which it
  /// never does.
  it("never calls a stored value a working credential", () => {
    const host = render({ current: { state: "set" } });
    expect(host.textContent).toContain(SECRET_SET_NOTE);
    expect(host.textContent).not.toMatch(/connected|authenticated|verified/i);
  });

  /// The read carries presence and never the value, so there is nothing
  /// to prefill — and a box that looked prefilled would invite a save that
  /// rewrote a key the person only meant to look at.
  it("opens an empty masked box rather than showing what is stored", async () => {
    const host = render({ current: { state: "set" } });
    expect(host.querySelector("input")).toBeNull();
    const replace = button(host, SECRET_REPLACE_ACTION);
    if (!replace) throw new Error("a stored key offers no replace");
    await userEvent.click(replace);
    const input = host.querySelector("input");
    expect(input?.type).toBe("password");
    expect(input?.value).toBe("");
  });

  /// A key nothing has answered opens with Set and offers no clear:
  /// there is nothing there to take out.
  it("offers set for a missing key and clear only for a stored one", () => {
    const missing = render();
    expect(button(missing, SECRET_SET_ACTION)).not.toBeNull();
    expect(button(missing, SECRET_CLEAR_ACTION)).toBeNull();
    const stored = render({ current: { state: "set" } });
    expect(button(stored, SECRET_CLEAR_ACTION)).not.toBeNull();
  });

  /// Every edit names the package whose template declares the key: core
  /// checks the edit against that declaration and refuses one written
  /// under somebody else's name.
  it("hands up a typed value bound to the package that declares the key", async () => {
    const onEdit = vi.fn();
    const host = render({}, { onEdit });
    const open = button(host, SECRET_SET_ACTION);
    if (!open) throw new Error("the field offered no set");
    await userEvent.click(open);
    const input = host.querySelector("input");
    if (!input) throw new Error("set opened no input");
    await userEvent.type(input, "k");
    expect(onEdit).toHaveBeenLastCalledWith({
      skill: "linear",
      key: "LINEAR_API_KEY",
      value: { kind: "set", value: "k" },
    });
  });

  it("hands up a clear as a clear, never as an empty value", async () => {
    const onEdit = vi.fn();
    const host = render({ current: { state: "set" } }, { onEdit });
    const clear = button(host, SECRET_CLEAR_ACTION);
    if (!clear) throw new Error("a stored key offered no clear");
    await userEvent.click(clear);
    expect(onEdit).toHaveBeenCalledWith({
      skill: "linear",
      key: "LINEAR_API_KEY",
      value: { kind: "clear" },
    });
  });

  /// The explanation is reachable by pointer, keyboard and screen reader
  /// alike, and it names the destination the read resolved — never the
  /// value.
  it("carries the same explanation in the trigger as in the popup", () => {
    const html = renderToStaticMarkup(
      <SecretFieldRow
        skill="linear"
        row={row()}
        file=".env.secrets"
        writable
        onEdit={() => {}}
        onCancel={() => {}}
      />,
    ).replaceAll("&#x27;", "'");
    expect(html).toContain(secretFieldHelp(".env.secrets"));
    expect(html).toContain(SECRET_REQUIRED);
  });

  /// Nothing may be written where the destination refuses, so the control
  /// that would write is held rather than failing on save.
  it("holds the set control where nothing can be written", () => {
    const host = render({}, { writable: false });
    expect(button(host, SECRET_SET_ACTION)?.disabled).toBe(true);
  });
});
