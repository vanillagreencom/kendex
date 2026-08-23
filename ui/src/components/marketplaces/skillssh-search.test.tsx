import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { SkillsShSearch } from "./skillssh-search";

const render = () =>
  renderToStaticMarkup(
    <SkillsShSearch onOpen={() => {}} onInstall={() => {}} />,
  );

describe("the skills.sh sub-tab's opening line", () => {
  it("promises a scan for risky patterns, never a verdict on the skill", () => {
    expect(render()).toContain(
      "installing brings the skill in the kendex way: subscribed, locked, and scanned for risky patterns before it lands.",
    );
  });
});
