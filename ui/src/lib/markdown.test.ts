import { describe, expect, it } from "vitest";
import {
  renderInlineMarkdown,
  renderMarkdown,
  stripFrontmatter,
} from "./markdown";

describe("renderMarkdown", () => {
  it("renders ordinary markdown", () => {
    const html = renderMarkdown("# Title\n\nSome **bold** text.");
    expect(html).toContain("<h1>Title</h1>");
    expect(html).toContain("<strong>bold</strong>");
  });

  it("escapes raw HTML instead of passing it through", () => {
    const html = renderMarkdown('<script>alert("hi")</script>\n\nText after.');
    expect(html).not.toContain("<script>");
    expect(html).toContain("&lt;script&gt;");
  });

  it("drops javascript: links but keeps their text", () => {
    const html = renderMarkdown("[click me](javascript:alert(1))");
    expect(html).not.toContain("javascript:");
    expect(html).toContain("click me");
    expect(html).not.toContain("<a ");
  });

  it("keeps HTTPS links with their isolation attributes", () => {
    const html = renderMarkdown("[docs](https://example.com/skill)");
    expect(html).toContain('href="https://example.com/skill"');
    expect(html).toContain('rel="noopener noreferrer"');
  });

  it("drops javascript: image sources but keeps the alt text", () => {
    const html = renderMarkdown("![alt](javascript:alert(1))");
    expect(html).not.toContain("<img");
    expect(html).toContain("alt");
  });

  it("highlights a fenced code block and still escapes its markup", () => {
    const source = '```js\nconst x = "<script>alert(1)</script>";\n```';
    const html = renderMarkdown(source);
    expect(html).not.toContain("<script>alert");
    expect(html).toContain("&lt;script&gt;");
    expect(html).toContain('class="hljs language-js"');
    expect(html).toContain("hljs-keyword");
  });

  it("falls back to escaped, unhighlighted text when nothing registered matches", () => {
    const html = renderMarkdown(
      "```cobol\nlorem ipsum dolor sit amet consectetur\n```",
    );
    expect(html).toContain("lorem ipsum dolor sit amet consectetur");
    expect(html).toContain('class="hljs"');
    expect(html).not.toContain("language-");
  });
});

describe("stripFrontmatter", () => {
  it("leaves content with no frontmatter untouched", () => {
    expect(stripFrontmatter("# Title\n\nBody.")).toBe("# Title\n\nBody.");
  });

  it("removes a terminated frontmatter block", () => {
    const source = "---\nname: deploy\ndescription: ships it\n---\n# Title\n";
    expect(stripFrontmatter(source)).toBe("# Title\n");
  });

  it("leaves an unterminated block alone rather than eating the rest", () => {
    const source = "---\nname: deploy\n\n# Title\n";
    expect(stripFrontmatter(source)).toBe(source);
  });
});

describe("renderInlineMarkdown", () => {
  it("gives file names and commands their own treatment", () => {
    const html = renderInlineMarkdown("Reads `kendex.toml` before it runs.");
    expect(html).toContain("<code>kendex.toml</code>");
  });

  it("stays on one line — block syntax is left as written", () => {
    const html = renderInlineMarkdown("# Not a heading\n- not a list");
    expect(html).not.toContain("<h1");
    expect(html).not.toContain("<ul");
  });

  it("leaves underscores inside an identifier alone", () => {
    const html = renderInlineMarkdown("Use pane_grid layout for this.");
    expect(html).not.toContain("<em>");
    expect(html).toContain("pane_grid layout");
  });

  it("escapes raw HTML, like the full renderer", () => {
    const html = renderInlineMarkdown('<img src=x onerror="alert(1)">');
    expect(html).not.toContain("<img");
    expect(html).toContain("&lt;img");
  });
});
