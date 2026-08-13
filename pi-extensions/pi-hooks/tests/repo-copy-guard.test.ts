import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { repoCopyRefusal } from "../extensions/repo-copy-guard.ts";

/**
 * Parity suite for `hooks/block-repo-copy.sh`. Fixtures are marker directories
 * built with mkdir/touch — nothing is ever copied or cloned.
 */

const FIX = mkdtempSync(join(tmpdir(), "pi-hooks-repo-copy-"));

// A git repository.
mkdirSync(join(FIX, "gitrepo/src"), { recursive: true });
mkdirSync(join(FIX, "gitrepo/.git"), { recursive: true });
// A Rust build tree, no repository history.
mkdirSync(join(FIX, "buildtree/target"), { recursive: true });
// A Node dependency tree.
mkdirSync(join(FIX, "nodetree/node_modules"), { recursive: true });
// A git worktree: `.git` is a FILE pointing at the common dir.
mkdirSync(join(FIX, "worktree"), { recursive: true });
writeFileSync(join(FIX, "worktree/.git"), "gitdir: /elsewhere/.git/worktrees/wt\n");
// The same shape with none of the markers.
mkdirSync(join(FIX, "plain/docs"), { recursive: true });
// A path whose name contains a space.
mkdirSync(join(FIX, "spaced dir/.git"), { recursive: true });

const CWD = "/home/agent/project";
const SCRATCH = "/tmp/block-repo-copy-dest";
const NON_SCRATCH = "/srv/archive/keepme";

function blocked(command: string, cwd = CWD): boolean {
	return repoCopyRefusal(command, cwd) !== undefined;
}

describe("blocked copy shapes", () => {
	test("cp -r of a git repo into /tmp", () => {
		expect(blocked(`cp -r ${FIX}/gitrepo ${SCRATCH}`)).toBe(true);
	});
	test("cp -R of a build tree into /tmp", () => {
		expect(blocked(`cp -R ${FIX}/buildtree ${SCRATCH}`)).toBe(true);
	});
	test("cp -a of a node_modules tree into /tmp", () => {
		expect(blocked(`cp -a ${FIX}/nodetree ${SCRATCH}`)).toBe(true);
	});
	test("a combined short-flag cluster still counts as recursive", () => {
		expect(blocked(`cp -rv ${FIX}/gitrepo ${SCRATCH}`)).toBe(true);
	});
	test("rsync -a of a git repo into /tmp", () => {
		expect(blocked(`rsync -a ${FIX}/gitrepo/ ${SCRATCH}`)).toBe(true);
	});
	test("rsync --archive of a build tree into /tmp", () => {
		expect(blocked(`rsync --archive ${FIX}/buildtree ${SCRATCH}`)).toBe(true);
	});
	test("git clone of a local repo into /tmp", () => {
		expect(blocked(`git clone ${FIX}/gitrepo ${SCRATCH}`)).toBe(true);
	});
	test("a tar create-to-extract pipe into /tmp", () => {
		expect(blocked(`tar -cf - -C ${FIX} gitrepo | tar -xf - -C ${SCRATCH}`)).toBe(true);
	});
	test("a tar pipe using cd for both ends", () => {
		expect(blocked(`(cd ${FIX} && tar cf - buildtree) | (cd ${SCRATCH} && tar xf -)`)).toBe(true);
	});
	test("the copy is found in a chained command", () => {
		expect(blocked(`mkdir -p ${SCRATCH} && cp -a ${FIX}/gitrepo ${SCRATCH}`)).toBe(true);
	});
	test("a worktree whose .git is a file is still a repository", () => {
		expect(blocked(`cp -r ${FIX}/worktree ${SCRATCH}`)).toBe(true);
	});
});

describe("scratch destination forms", () => {
	test("/var/tmp is scratch", () => {
		expect(blocked(`cp -r ${FIX}/gitrepo /var/tmp/keep`)).toBe(true);
	});
	test("an unexpanded $TMPDIR destination is scratch", () => {
		expect(blocked(`cp -r ${FIX}/gitrepo $TMPDIR/keep`)).toBe(true);
	});
	test("an unexpanded $CLAUDE_CODE_TMPDIR destination is scratch", () => {
		expect(blocked(`cp -r ${FIX}/gitrepo $CLAUDE_CODE_TMPDIR/keep`)).toBe(true);
	});
	test("a mktemp -d destination is scratch", () => {
		expect(blocked(`cp -r ${FIX}/gitrepo $(mktemp -d)`)).toBe(true);
	});
	test("a path containing scratchpad is scratch", () => {
		expect(blocked(`cp -r ${FIX}/gitrepo /home/agent/scratchpad/copy`)).toBe(true);
	});
	test("an unexpanded variable naming no temp root is not scratch", () => {
		expect(blocked(`cp -r ${FIX}/gitrepo $HOME/keep`)).toBe(false);
	});
});

describe("the destination the shell would actually write to", () => {
	test("cp -t names the destination, which is not the last operand", () => {
		expect(blocked(`cp -r -t ${SCRATCH} ${FIX}/gitrepo`)).toBe(true);
	});
	test("cp --target-directory=DIR names the destination", () => {
		expect(blocked(`cp -r --target-directory=${SCRATCH} ${FIX}/gitrepo`)).toBe(true);
	});
	test("cp -rt DIR carries the target inside the short cluster", () => {
		expect(blocked(`cp -rt ${SCRATCH} ${FIX}/gitrepo`)).toBe(true);
	});
	test("a target-directory outside scratch is allowed", () => {
		expect(blocked(`cp -r --target-directory=${NON_SCRATCH} ${FIX}/gitrepo`)).toBe(false);
	});
	test("rsync -t is --times, so the last operand stays the destination", () => {
		expect(blocked(`rsync -rt ${FIX}/gitrepo ${SCRATCH}`)).toBe(true);
	});
	test("a relative destination resolves against an earlier cd", () => {
		expect(blocked(`cd ${SCRATCH} && cp -r ${FIX}/gitrepo copy`)).toBe(true);
	});
	test("cd then git clone with no destination", () => {
		expect(blocked(`cd /tmp && git clone ${FIX}/gitrepo`)).toBe(true);
	});
	test("a cd to an ordinary directory leaves relative copies alone", () => {
		expect(blocked(`cd ${NON_SCRATCH} && cp -r ${FIX}/gitrepo copy`)).toBe(false);
	});
	test("a cd inside a subshell group does not leak past the group", () => {
		expect(blocked(`(cd ${SCRATCH} && ls) && cp -r ${FIX}/gitrepo copy`)).toBe(false);
	});
	test("a quoted source path containing a space stays one operand", () => {
		expect(blocked(`cp -r "${FIX}/spaced dir" ${SCRATCH}`)).toBe(true);
	});
	test("a variable assigned mktemp -d earlier in the command is scratch", () => {
		expect(blocked(`d=$(mktemp -d); cp -r ${FIX}/gitrepo "$d"`)).toBe(true);
	});
	test("an option argument is not counted as an operand", () => {
		expect(blocked(`git clone --depth 1 ${FIX}/gitrepo ${SCRATCH}`)).toBe(true);
	});
	test("an rsync option argument is not counted as an operand", () => {
		expect(blocked(`rsync -a --exclude target ${FIX}/gitrepo ${SCRATCH}`)).toBe(true);
	});
});

describe("commands that must pass", () => {
	test("a source with no repository or build tree", () => {
		expect(blocked(`cp -r ${FIX}/plain ${SCRATCH}`)).toBe(false);
	});
	test("an expensive tree copied to a non-scratch destination", () => {
		expect(blocked(`cp -r ${FIX}/buildtree ${NON_SCRATCH}`)).toBe(false);
	});
	test("a repository subdirectory carrying no markers of its own", () => {
		expect(blocked(`cp -r ${FIX}/gitrepo/src ${SCRATCH}`)).toBe(false);
	});
	test("a non-recursive single-file copy", () => {
		expect(blocked(`cp ${FIX}/plain/README.md ${SCRATCH}/README.md`)).toBe(false);
	});
	test("a small legitimate directory copy into scratch", () => {
		expect(blocked(`cp -r ${FIX}/plain/docs ${SCRATCH}/docs`)).toBe(false);
	});
	test("rsync -R is --relative, not recursion", () => {
		expect(blocked(`rsync -R ${FIX}/gitrepo ${SCRATCH}`)).toBe(false);
	});
	test("a non-copy command", () => {
		expect(blocked("git status --short")).toBe(false);
	});
	test("reading a repository next to a scratch path is not a copy", () => {
		expect(blocked(`ls -la ${FIX}/gitrepo ${SCRATCH}`)).toBe(false);
	});
});

describe("the refusal names the cause", () => {
	test("source, marker, and destination", () => {
		const refusal = repoCopyRefusal(`cp -r ${FIX}/buildtree ${SCRATCH}`, CWD);
		expect(refusal).toBeDefined();
		expect(refusal?.source).toBe(join(FIX, "buildtree"));
		expect(refusal?.markers).toEqual(["target"]);
		expect(refusal?.destination).toBe(SCRATCH);
	});
});

describe("cleanup", () => {
	test("fixtures removed", () => {
		rmSync(FIX, { recursive: true, force: true });
		expect(true).toBe(true);
	});
});
