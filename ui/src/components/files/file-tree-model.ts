import type { ReactNode } from "react";

/** One file a surface wants listed, with whatever that surface says about
 *  it — a size, a `+n −n` pair, a status word — drawn at the row's right
 *  edge. The path is forward-slashed and relative to whatever root the
 *  surface is about, which is what every producer in the app already
 *  emits. */
export interface FileEntry {
  path: string;
  meta?: ReactNode;
}

/** A folder, or a file inside one. Folders carry their children; a file
 *  carries the entry it was built from, so a row can draw its meta without
 *  a second lookup. */
export type TreeNode =
  | { kind: "folder"; name: string; path: string; children: TreeNode[] }
  | { kind: "file"; name: string; path: string; entry: FileEntry };

interface Folder {
  children: Map<string, Folder | FileEntry>;
}

const isFolder = (node: Folder | FileEntry): node is Folder =>
  "children" in node;

/** Group flat paths into folders, the way a code editor shows a checkout.
 *
 *  Two files under `a/b/` share one `a` and one `a/b`. Folders come before
 *  files at every level and each run is sorted by name, so the same set of
 *  paths always draws the same tree whatever order the producer listed
 *  them in.
 *
 *  A path segment that is empty — a leading, doubled or trailing slash —
 *  is dropped rather than drawn as a nameless folder; a path left with no
 *  segments at all is not a file and is dropped whole. */
export function buildFileTree(entries: FileEntry[]): TreeNode[] {
  const root: Folder = { children: new Map() };
  for (const entry of entries) {
    const segments = entry.path.split("/").filter((one) => one !== "");
    const name = segments.pop();
    if (name === undefined) continue;
    let at = root;
    for (const segment of segments) {
      const next = at.children.get(segment);
      if (next !== undefined && isFolder(next)) {
        at = next;
        continue;
      }
      // A path that is a file on one row and a folder prefix on another
      // cannot both be drawn; the folder wins, because the row under it
      // would otherwise have nowhere to sit.
      const made: Folder = { children: new Map() };
      at.children.set(segment, made);
      at = made;
    }
    at.children.set(name, entry);
  }
  return nodesOf(root, "");
}

function nodesOf(folder: Folder, prefix: string): TreeNode[] {
  const folders: TreeNode[] = [];
  const files: TreeNode[] = [];
  for (const [name, child] of folder.children) {
    const path = prefix === "" ? name : `${prefix}/${name}`;
    if (isFolder(child)) {
      folders.push({
        kind: "folder",
        name,
        path,
        children: nodesOf(child, path),
      });
    } else {
      files.push({ kind: "file", name, path: child.path, entry: child });
    }
  }
  const byName = (a: TreeNode, b: TreeNode) => a.name.localeCompare(b.name);
  folders.sort(byName);
  files.sort(byName);
  return [...folders, ...files];
}
