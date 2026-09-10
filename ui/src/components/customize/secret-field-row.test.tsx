// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { SecretEdit, SecretRow } from "@/bindings";
import {
  SECRET_CANCEL_ACTION,
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

  /// A save clears every edit and leaves this row mounted, so the box has
  /// to close with the draft that was typed into it. Left open it would
  /// stand as an empty password input exactly where the saved key's
  /// Set/Replace controls belong, inviting a second save of nothing.
  ///
  /// The inverse is the other half of the rule: a box opened and never
  /// typed into is the person's own and stays open, because no answer of
  /// theirs went away.
  it("closes the box when the draft it was typed into is cleared", async () => {
    function Draft() {
      const [edit, setEdit] = useState<SecretEdit | undefined>(undefined);
      return (
        <>
          <SecretFieldRow
            skill="linear"
            row={row({ current: { state: "set" } })}
            file=".env.local"
            writable
            edit={edit}
            onEdit={setEdit}
            onCancel={() => setEdit(undefined)}
          />
          <button type="button" onClick={() => setEdit(undefined)}>
            saved
          </button>
        </>
      );
    }
    const host = mount(<Draft />);
    const replace = button(host, SECRET_REPLACE_ACTION);
    if (!replace) throw new Error("a stored key offers no replace");
    await userEvent.click(replace);

    // Opened and not yet typed into: the person's own box, left alone.
    const saved = button(host, "saved");
    if (!saved) throw new Error("the harness offered no save");
    await userEvent.click(saved);
    expect(host.querySelector("input")).not.toBeNull();

    const input = host.querySelector("input");
    if (!input) throw new Error("replace opened no input");
    await userEvent.type(input, "k");
    expect(host.querySelector("input")?.value).toBe("k");

    // The answer goes away with the save, and the box goes with it.
    await userEvent.click(saved);
    expect(host.querySelector("input")).toBeNull();
    expect(button(host, SECRET_REPLACE_ACTION)).not.toBeNull();
  });

  /// A box opened while the destination was writable stays mounted when a
  /// pick resolves to a refused one, or when the key turns out to be one
  /// core will not write over. Typing into it then stages a write that
  /// Save is certain to refuse, so the input carries the same condition
  /// the buttons do — while Cancel stays live, because taking the draft
  /// back is exactly what is left to do.
  it("disables the open input when nothing can be written there", async () => {
    const onEdit = vi.fn();
    const host = render({}, { onEdit });
    const open = button(host, SECRET_SET_ACTION);
    if (!open) throw new Error("the field offered no set");
    await userEvent.click(open);
    expect(host.querySelector("input")?.disabled).toBe(false);

    for (const props of [
      { writable: false },
      { row: row({ current: { state: "unknown", reason: "assigned twice" } }) },
    ]) {
      const shut = mount(
        <SecretFieldRow
          skill="linear"
          row={row()}
          file=".env.local"
          writable
          edit={{
            skill: "linear",
            key: "LINEAR_API_KEY",
            value: { kind: "set", value: "k" },
          }}
          onEdit={onEdit}
          onCancel={() => {}}
          {...props}
        />,
      );
      const input = shut.querySelector("input");
      expect(input).not.toBeNull();
      expect(input?.disabled).toBe(true);
      expect(button(shut, SECRET_CANCEL_ACTION)).not.toBeNull();
    }
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
  /// value. A static render shows the trigger's own copy; the popup reads
  /// the same value, so the two cannot say different things.
  it("carries the explanation in the trigger, naming the resolved file", () => {
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

  /// The tooltip repeats the section's safety claim, so it has to stop
  /// making it where the destination refuses — the warning beside it
  /// often says git carries that very file.
  it("claims nothing about git where the destination refuses", () => {
    const html = renderToStaticMarkup(
      <SecretFieldRow
        skill="linear"
        row={row()}
        file=".env.local"
        writable={false}
        onEdit={() => {}}
        onCancel={() => {}}
      />,
    ).replaceAll("&#x27;", "'");
    expect(html).toContain(secretFieldHelp(".env.local", false));
    expect(html).not.toContain(secretFieldHelp(".env.local"));
    expect(html).not.toMatch(/keeps out of git/);
  });

  /// Nothing may be written where the destination refuses, so the control
  /// that would write is held rather than failing on save. Clear is held
  /// with it: core refuses the whole draft before it applies any edit, so
  /// a staged clear would fail at Save just the same.
  it("holds every write control where the destination refuses", () => {
    const host = render({ current: { state: "set" } }, { writable: false });
    expect(button(host, SECRET_REPLACE_ACTION)?.disabled).toBe(true);
    expect(button(host, SECRET_CLEAR_ACTION)?.disabled).toBe(true);
  });

  /// A key core will not write over — assigned more than once, or in a
  /// shape kendex does not write — is what leaves the row unknown. The
  /// destination is fine, so `writable` says nothing about it, and a value
  /// typed here would be refused on Save.
  it("holds every write control for a key core will not write over", () => {
    const host = render({
      current: { state: "unknown", reason: "it is assigned more than once" },
    });
    expect(button(host, SECRET_SET_ACTION)?.disabled).toBe(true);
    // The control this reads against: the same row with a state core can
    // write leaves the button live.
    const settable = render({ current: { state: "not-set" } });
    expect(button(settable, SECRET_SET_ACTION)?.disabled).toBe(false);
  });
});
