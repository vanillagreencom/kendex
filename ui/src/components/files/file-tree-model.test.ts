import { describe, expect, it } from "vitest";
import { buildFileTree, type TreeNode } from "./file-tree-model";

/** A node as one line: `folder a`, `file a/b.md`. Whole-tree assertions
 *  read as the shape a person sees rather than as nested objects. */
function lines(nodes: TreeNode[], depth = 0): string[] {
  return nodes.flatMap((node) => [
    `${"  ".repeat(depth)}${node.kind} ${node.path}`,
    ...(node.kind === "folder" ? lines(node.children, depth + 1) : []),
  ]);
}

const tree = (paths: string[]) =>
  buildFileTree(paths.map((path) => ({ path })));

describe("buildFileTree", () => {
  it("groups paths into folders, folders before files, each by name", () => {
    expect(
      lines(
        tree([
          "SKILL.md",
          "scripts/run.sh",
          "references/b.md",
          "references/a.md",
          "AGENTS.md",
        ]),
      ),
    ).toEqual([
      "folder references",
      "  file references/a.md",
      "  file references/b.md",
      "folder scripts",
      "  file scripts/run.sh",
      "file AGENTS.md",
      "file SKILL.md",
    ]);
  });

  it("shares one folder between the files under it, however deep", () => {
    expect(lines(tree(["a/b/c/one.md", "a/b/two.md", "a/three.md"]))).toEqual([
      "folder a",
      "  folder a/b",
      "    folder a/b/c",
      "      file a/b/c/one.md",
      "    file a/b/two.md",
      "  file a/three.md",
    ]);
  });

  // The tree is drawn from paths a command answered with; a leading,
  // doubled or trailing slash would otherwise draw a folder with no name
  // that no row sits under.
  it("drops empty segments and a path that is nothing but slashes", () => {
    expect(lines(tree(["/a//b.md", "c/", "/"]))).toEqual([
      "folder a",
      "  file /a//b.md",
      "file c/",
    ]);
  });

  // A comparison that replaces a file with a directory of the same name
  // holds both, and dropping either would leave a change the person cannot
  // open at all — in the commit dialog, cannot even see.
  it("keeps a name that is a file and a folder at once, both ways round", () => {
    expect(lines(tree(["foo", "foo/bar"]))).toEqual([
      "folder foo",
      "  file foo/bar",
      "file foo",
    ]);
    expect(lines(tree(["foo/bar", "foo"]))).toEqual([
      "folder foo",
      "  file foo/bar",
      "file foo",
    ]);
  });

  it("gives the file row and the folder row of one name different keys", () => {
    const keys = buildFileTree([{ path: "foo" }, { path: "foo/bar" }]).map(
      (node) => node.key,
    );
    expect(keys).toEqual(["folder:foo", "file:foo"]);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it("keeps each file's own entry so a row can draw what came with it", () => {
    const [node] = buildFileTree([{ path: "a/b.md", meta: "10 B" }]);
    expect(node?.kind === "folder" && node.children[0]).toMatchObject({
      kind: "file",
      name: "b.md",
      entry: { path: "a/b.md", meta: "10 B" },
    });
  });
});
