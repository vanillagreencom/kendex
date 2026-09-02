// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { mount } from "@/test/dom";
import { Segmented } from "./segmented";

const options = [
  { value: "one" as const, label: "One" },
  { value: "two" as const, label: "Two" },
];

const draw = (value: "one" | "two", onChange = vi.fn()) => {
  const host = mount(
    <Segmented
      value={value}
      onChange={onChange}
      options={options}
      label="Which"
    />,
  );
  const inputs = [
    ...host.querySelectorAll<HTMLInputElement>('input[type="radio"]'),
  ];
  return { host, inputs, onChange };
};

describe("a segmented control", () => {
  it("marks exactly the chosen option", () => {
    const { inputs } = draw("two");
    expect(inputs.map((input) => input.checked)).toEqual([false, true]);
  });

  it("answers with the option that was clicked", async () => {
    const { inputs, onChange } = draw("one");
    await userEvent.click(inputs[1]);
    expect(onChange).toHaveBeenCalledWith("two");
  });

  // Two controls on one page sharing a radio name become one group, and
  // choosing in either would clear the other. The name comes from useId,
  // so each mounted control gets its own.
  it("keeps two mounted controls from becoming one group", () => {
    const first = draw("one").inputs;
    const second = draw("one").inputs;
    expect(new Set(first.map((input) => input.name)).size).toBe(1);
    expect(first[0].name).not.toBe(second[0].name);
  });
});
