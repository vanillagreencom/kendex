"""Read committed workflow lanes for change-class. Exit 3 when no workflow uses them."""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tomllib
from collections import defaultdict
from functools import cached_property


class Unreadable(Exception):
    # A shape refusal judges the job's own text and sources at the base, which
    # a lane's reasoned claims describe. Any other refusal, from a tool on this
    # run, from a read of the change itself or from inside the Cargo reader,
    # leaves the job's reads unknown.
    shape = False


class ShapeUnreadable(Unreadable):
    shape = True


class NamedUnreadable(Unreadable):
    # The cause names the input it failed on, so the job's dispatches add nothing.
    def __init__(self, cause, shape):
        super().__init__(cause)
        self.shape = shape


def is_shape(error):
    return isinstance(error, Unreadable) and error.shape


def require(condition, cause):
    if not condition:
        raise Unreadable(cause)


def require_shape(condition, cause):
    if not condition:
        raise ShapeUnreadable(cause)


def command(args, cwd, *, data=None, env=None):
    result = subprocess.run(
        args, cwd=cwd, input=data, capture_output=True, env=env, timeout=45, check=False,
    )
    require(result.returncode == 0, f"{Path(args[0]).name}-exit-{result.returncode}")
    return result.stdout


def under(path, directory):
    return directory == "." or path == directory or path.startswith(directory + "/")


def literal(value):
    return re.fullmatch(r"[A-Za-z0-9_./+-]+", value) and not value.startswith("/")


def words(line):
    if line.lstrip().startswith("#"):
        return []
    try:
        tokens = shlex.split(line)
    except ValueError as error:
        raise ShapeUnreadable(str(error)) from error
    require_shape(all(literal(word) or word == ":" for word in tokens), "computed-command")
    return tokens


def lane_invocation(args):
    return len(args) == 3 and args[1] == "--lane" and "/" in args[0]


ACTIONS = r"vanillagreencom/kendex/\.github/actions/change-class@[^\s]+"
LANE_ID = r"[a-z0-9][a-z0-9_-]*"
RENDER = (".agents/", ".claude/", ".codex/", ".pi/")
# kendex parks a switched-off skill's SKILL.md under the second name.
SKILL_MARKERS = ("SKILL.md", "SKILL.md.disabled")
MODULE = re.compile(r"\.(?:[cm]?[jt]s|[jt]sx)$")
JS_TRIVIA = r"(?:\s|/\*[\s\S]*?\*/|//[^\n]*(?:\n|$))*"
JS_REFERENCE = re.compile(r"\b(?:import\b" + JS_TRIVIA + r"(\(" + JS_TRIVIA +
                          r")?|from\b" + JS_TRIVIA + r")")
JS_SPECIFIER = re.compile(r"""(['"])([^'"\\\r\n]+)\1""")
VITEST_STATIC_IMPORT = re.compile(
    r"\s*import\s*\{\s*([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*,?\s*\}\s*"
)
JS_CONFIG = {"jsconfig.json", "tsconfig.json"}
# Vitest 4 looks for these, with any script extension, in its root and then
# each ancestor: any(configFiles, { cwd: root }) in vitest/dist/node.js.
VITEST_CONFIG = ("vitest.config.", "vite.config.")
JS_PACKAGES = {"package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"}
CHECKOUT = r"actions/checkout@[^\s]+"
# A symlink or a submodule: git tracks no entry below either.
LINK_MODES = {"120000", "160000"}
UNAVAILABLE = (Unreadable, OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired)
BASH_SHEBANGS = [["#!/usr/bin/env bash"], ["#!/bin/bash"]]
STRICT_MODE = [["set -euo pipefail"], ["set -eu"]]
LANE_TABLE_DISPATCH = """case ${1-} in
--lane) run=$2 ;;
*) exit 2 ;;
esac
for entry in "${lane_table[@]}"; do
name=${entry%%:*}
[ "$name" = "$run" ] || continue
for member in ${entry#*:}; do
case $member in
@*|+host|+isolated) ;;
*) "step_${member//-/_}" ;;
esac
done
done""".splitlines()
# The same dispatch, then the lane's fixture files: each .sh and .py file
# directly in bin/fixtures/LANE/, listed when the lane runs. The list is on
# fd 3, so a fixture that reads stdin cannot consume it.
LANE_FIXTURE_DISPATCH = """case ${1-} in
--lane) run=$2 ;;
*) exit 2 ;;
esac
for entry in "${lane_table[@]}"; do
name=${entry%%:*}
[ "$name" = "$run" ] || continue
for member in ${entry#*:}; do
case $member in
@*|+host|+isolated|*.sh|*.py) ;;
*) "step_${member//-/_}" ;;
esac
done
[ -d "bin/fixtures/$name" ] || continue
fixtures=$(find "bin/fixtures/$name" -mindepth 1 -maxdepth 1 -type f \\( -name '*.sh' -o -name '*.py' \\) | LC_ALL=C sort)
while IFS= read -r fixture <&3; do
case $fixture in
*.sh) bash "$fixture" ;;
*.py) python3 "$fixture" ;;
esac
done 3<<<"$fixtures"
done""".splitlines()
SHELL_KEYWORDS = {
    "case", "coproc", "do", "done", "elif", "else", "esac", "fi", "for",
    "function", "if", "in", "select", "then", "time", "until", "while",
}
FORWARD_VERDICTS = re.compile(r'''printf '%s\\n' "\$LANE_VERDICTS"[ \t]*>>[ \t]*"\$GITHUB_OUTPUT"''')
OUTPUT_ID = r"[A-Za-z_][A-Za-z0-9_-]*"
NARROWED_LANES = re.compile(
    rf"\$\{{\{{ steps\.({OUTPUT_ID})\.outputs\.({OUTPUT_ID}) == 'true' && 'false' \|\| "
    rf"steps\.({OUTPUT_ID})\.outputs\.lanes \}}\}}"
)
QUEUE_NARROWING = re.compile(
    r'''(?P<deferred>[A-Za-z_]\w*)=false\n'''
    r'''if \[ "\$(?P<event>[A-Za-z_]\w*)" = pull_request \] && \[ "\$(?P<queue>[A-Za-z_]\w*)" = true \] && '''
    + re.escape('''grep -q '^lane_[a-z0-9_-]*=false$' <<<"$LANE_VERDICTS"; then''')
    + rf'''\n(?P=deferred)=true\n(?:echo 'lane_{LANE_ID}=false'[ \t]*>>[ \t]*"\$GITHUB_OUTPUT"\n)+'''
    r'''fi\necho "queue_deferred=\$(?P=deferred)"[ \t]*>>[ \t]*"\$GITHUB_OUTPUT"'''
)


# A ${...} expansion holding no brace, quote, blank, backslash or operator,
# so its "}" cannot be a word of its own, even where a quote around it
# makes the "${" plain text.
PLAIN_EXPANSION = re.compile(r"\$\{[^{}\s'\"`\\;&|<>()]*\}")


def boundary_unproved(body):
    # Whether bash could end the function before the line that is "}" alone,
    # so lines after it would run at the top level. The rule reads no quote
    # or comment: any brace outside a plain expansion counts, and so does a
    # line continuation or a "<<", which can join lines or hide them.
    return any(re.search(r"[{}]", PLAIN_EXPANSION.sub("", line)) or line.endswith("\\")
               or "<<" in line for line in body)


def lane_table(lines, lane):
    """The lane's step names, the runner's step bodies, and whether the runner
    also runs the lane's fixture directory."""
    dispatch = next((shape for shape in (LANE_TABLE_DISPATCH, LANE_FIXTURE_DISPATCH)
                     if len(lines) > len(shape) and lines[-len(shape):] == shape), None)
    require_shape(dispatch and lines[0] == "lane_table=(", "unsupported-runner-dispatch")
    fixtures = dispatch is LANE_FIXTURE_DISPATCH
    end = len(lines) - len(dispatch)
    index = 1
    members = {}
    while index < end and lines[index] != ")":
        entry = re.fullmatch(rf'"({LANE_ID}):', lines[index])
        require_shape(entry and entry[1] not in members and '"' in lines[index + 1:end],
                      "unsupported-runner-table")
        close = lines.index('"', index + 1, end)
        selected = []
        for word in " ".join(lines[index + 1:close]).split():
            if re.fullmatch(r"@[A-Za-z0-9_./+*?-]+|\+(?:host|isolated)", word) or (
                fixtures and re.fullmatch(r"[A-Za-z0-9_.-]+\.(?:sh|py)", word)
            ):
                continue
            require_shape(re.fullmatch(LANE_ID, word), "unsupported-runner-member")
            selected.append(word)
        members[entry[1]] = selected
        index = close + 1
    # A lane with no step can still run its fixture files.
    require_shape(index < end and lane in members and (fixtures or members[lane]),
                  "runner-lane-unresolved")
    index += 1
    functions = {}
    while index < end:
        definition = re.fullmatch(r"(step_[a-z0-9_]+)\(\) \{", lines[index])
        require_shape(definition and definition[1] not in functions and "}" in lines[index + 1:end],
                      "unsupported-runner-function")
        close = lines.index("}", index + 1, end)
        # The caller reads only the selected lane's steps, so another step's
        # body must end where this split ends it.
        require_shape(not boundary_unproved(lines[index + 1:close]),
                      f"runner-function-boundary-unproved function={definition[1]}")
        functions[definition[1]] = lines[index + 1:close]
        index = close + 1
    return members[lane], functions, fixtures


class Evidence:
    def __init__(self, repo, authority, compared, head, work, trusted, rendered):
        self.repo = Path(repo).resolve()
        self.authority = authority
        self.head = head
        self.work = Path(work).resolve()
        self.trusted = Path(trusted).resolve() if trusted else None
        self.rendered = rendered
        self.compared = compared
        self.changed = set((self.work / "derived-paths").read_text().split("\0")[:-1])
        self.files = self.tree(authority)

    def git(self, *args):
        return command(["git", *args], self.repo)

    def tree(self, rev):
        rows = self.git("ls-tree", "-rz", rev).decode().split("\0")[:-1]
        return {row.split("\t", 1)[1]: row.split(" ", 1)[0] for row in rows}

    def blob(self, path, rev=None):
        if rev is None:
            require_shape(self.files.get(path) in {"100644", "100755"}, "non-regular-input")
        return self.git("cat-file", "blob", f"{rev or self.authority}:{path}").decode()

    @cached_property
    def checkout(self):
        path = self.work / "graph-base"
        # Use a private checkout and index. Vitest's --changed must see the
        # judged path names as staged changes while reading only base bytes.
        command(["git", "clone", "--quiet", "--shared", "--no-checkout",
                 str(self.repo), str(path)], self.work)
        command(["git", "-c", "core.hooksPath=/dev/null", "checkout", "--quiet",
                 "--detach", self.authority], path)
        return path

    @cached_property
    def head_files(self):
        return self.tree(self.head)

    def relative(self, path):
        return Path(path).resolve().relative_to(self.checkout).as_posix()

    @cached_property
    def ownership(self):
        return self.owners_at(None)

    @cached_property
    def proved_head_ownership(self):
        return self.owners_at(self.head)

    def owners_at(self, rev):
        try:
            inventory = json.loads(self.blob(".kendex-generated.json", rev))
            entries = json.loads(self.blob(".kendex-lock.json", rev))["entries"]
            require(isinstance(inventory, list), "invalid-inventory")
            require(isinstance(entries, dict), "invalid-install-record")
            inventory = {
                row if isinstance(row, str) else row["path"] for row in inventory
            }
            owners = defaultdict(set)
            # A switched-off installation keeps its files on disk, so its
            # record still owns them.
            for key, entry in entries.items():
                emitted = entry.get("emitted")
                if emitted is None:
                    continue
                # kendex keys an entry KIND:NAME:HARNESS by its declaration.
                # The emitted kind and name can differ by harness: a Codex
                # command is emitted as a skill, possibly renamed.
                kind, _, rest = key.partition(":")
                name, _, harness = rest.rpartition(":")
                require(kind and name and harness, "invalid-install-key")
                package = (entry["sourceRepo"], kind, name)
                for path in inventory:
                    if any(under(path, position) for position in emitted["paths"]):
                        owners[path].add(package)
            return {path: next(iter(packages)) for path, packages in owners.items()
                    if len(packages) == 1}
        except UNAVAILABLE:
            return {}

    def owner(self, path):
        if path in self.files:
            return self.ownership.get(path)
        if self.rendered:
            return self.proved_head_ownership.get(path)
        return None

    def package_path(self, path):
        # A skill's marker keeps it a candidate when its ownership is unreadable.
        return path.startswith(RENDER) or self.owner(path) is not None or any(
            (parent / name).as_posix() in self.files
            for parent in Path(path).parents for name in SKILL_MARKERS
        )

    def shell_reads(self, script, directory, reads, visited):
        invocation = (script, directory)
        if invocation in visited:
            return
        visited.add(invocation)
        reads.add(script)
        for line in self.blob(script).splitlines():
            args = words(line)
            if args:
                self.shell_command(args, directory, reads, visited)

    def lane_dispatch(self, args, directory, reads, visited):
        name, _, lane = args
        try:
            script, passed = self.resolve(directory, name)
            reads.update({script} | passed)
            invocation = (script, directory, lane)
            if invocation in visited:
                return
            visited.add(invocation)
            body = self.blob(script).split("\n")
            require_shape(self.files[script] == "100755" and body[:1] in BASH_SHEBANGS,
                          "unsupported-runner-interpreter")
            lines = [line.strip(" \t") for line in body[1:] if line.strip(" \t")]
            if lines[:1] in STRICT_MODE:
                lines = lines[1:]
            members, functions, fixtures = lane_table(lines, lane)
            for member in members:
                step = "step_" + member.replace("-", "_")
                require_shape(step in functions, f"runner-step-unresolved step={step}")
                body = [args for line in functions[step] if (args := words(line))]
                require_shape(body and all(args[0] not in SHELL_KEYWORDS for args in body),
                              f"unsupported-runner-body step={step}")
                for command in body:
                    self.shell_command(command, directory, reads, visited)
            if fixtures:
                self.lane_fixtures(lane, directory, reads, visited)
        except UNAVAILABLE as error:
            raise NamedUnreadable(
                f"unresolved-lane-dispatch command={shlex.join(args)} reason={error}", is_shape(error),
            ) from error

    def lane_fixtures(self, lane, directory, reads, visited):
        folder, passed = self.checkout_path(directory, f"bin/fixtures/{lane}")
        reads.update(passed)
        # The runner lists the directory when the lane runs, so a path added,
        # removed or changed in it, or a change to the directory itself or an
        # ancestor, reaches the lane.
        reads.update(name for name in self.changed if under(name, folder) or under(folder, name))
        for path, mode in sorted(self.files.items()):
            # find -type f lists regular files and no link.
            if (Path(path).parent.as_posix() != folder or mode not in {"100644", "100755"}
                    or not path.endswith((".sh", ".py"))):
                continue
            # The runner reads the list by line, so it would run each part of
            # a name that holds a newline as a path of its own.
            require_shape("\n" not in path, f"runner-fixture-name-newline folder={folder}")
            require_shape(not path.endswith(".py"), f"runner-fixture-opaque fixture={path}")
            self.shell_reads(path, directory, reads, visited)

    def shell_command(self, args, directory, reads, visited):
        name, *operands = args
        if name in {"source", ".", "bash"} and len(operands) == 1:
            require_shape(name == "bash" or "/" in operands[0], "shell-source-uses-path")
            script, passed = self.resolve(directory, operands[0])
            reads.update(passed)
            self.shell_reads(script, directory, reads, visited)
        elif lane_invocation(args):
            require_shape(re.fullmatch(LANE_ID, operands[1]), "invalid-runner-lane")
            self.lane_dispatch(args, directory, reads, visited)
        elif name.startswith("./") and not operands:
            script, passed = self.resolve(directory, name)
            reads.update({script} | passed)
            require_shape(self.files.get(script) == "100755" and self.blob(script).splitlines()[:1]
                          in [*BASH_SHEBANGS, ["#!/bin/sh"]],
                          "unsupported-script-interpreter")
            self.shell_reads(script, directory, reads, visited)
        elif name == "cat" and operands and all(literal(path) for path in operands):
            for path in operands:
                path, passed = self.resolve(directory, path)
                reads.update({path} | passed)
        elif name == "test":
            require_shape(len(operands) == 2 and operands[0] in {"-f", "-r", "-e"},
                          "unsupported-shell-test")
            path, passed = self.resolve(directory, operands[1])
            reads.update({path} | passed)
            reads.update(name for name in self.changed if under(name, path))
        elif name == "set" and operands in [["-euo", "pipefail"], ["-eu"]]:
            return
        else:
            require_shape(name in {":", "true", "false"} and not operands, "opaque-shell-command")

    def resolve(self, directory, path):
        require_shape(literal(path) and not path.startswith("-"), "computed-path")
        return self.checkout_path(directory, path)

    def checkout_path(self, directory, path):
        original = Path(directory) / path
        prefixes = [os.path.normpath(prefix) for prefix in original.parents]
        # Check each original prefix before a later '..' can hide a link.
        for prefix in (os.path.normpath(original), *prefixes):
            require_shape(self.files.get(prefix) not in LINK_MODES, "indirect-path")
        result = os.path.normpath(original)
        require_shape(result not in {"..", "."} and not result.startswith("../"), "path-outside-repo")
        # A kernel walk must enter each directory the path names before a
        # later '..' leaves it, and the result's own existence does not prove
        # that directory exists. The starting directory has its own evidence.
        # The changed paths under those directories are returned apart, for
        # the readers whose tool walks the path that way.
        passed = {name for prefix in prefixes[:len(Path(path).parts) - 1]
                  if not under(result, prefix)
                  for name in self.changed if under(name, prefix)}
        return result, passed

    def working_directory(self, directory, reads):
        # A checkout materializes a directory through its tracked entries, and
        # git tracks none below a link. One absent at both ends, such as a
        # checkout's own path, is the job's shape, and so is one reached
        # through the same links at both ends. One the change adds, removes or
        # swaps with a link leaves the job unread.
        original = Path(directory)
        result = os.path.normpath(original)
        prefixes = {os.path.normpath(prefix) for prefix in (original, *original.parents)}

        def state(files):
            links = frozenset(prefix for prefix in prefixes if files.get(prefix) in LINK_MODES)
            present = any(path.startswith(result + "/") for path in files)
            return ("link" if links else "directory" if present else "absent"), links

        base, head = state(self.files), state(self.head_files)
        reads.update(base[1] | head[1])
        require(base == head, "working-directory-unproved")
        if base[0] == "link":
            self.link_reads(directory, reads)
            raise ShapeUnreadable("indirect-path")
        result, passed = self.resolve(".", directory)
        reads.update(passed)
        require_shape(base[0] == "directory", "working-directory-unproved")
        return result

    def link_reads(self, path, reads):
        """Record each base link a kernel walk of path follows, and the changed
        paths under where the walk ends. A link the change replaces is itself
        a changed path, so no head link is followed."""
        parts = list(Path(path).parts)
        current = []
        followed = 0
        while parts:
            part = parts.pop(0)
            if part == "..":
                if not current:
                    # The walk leaves the tree, where the change reaches nothing.
                    return
                current.pop()
                continue
            current.append(part)
            name = "/".join(current)
            if self.files.get(name) not in LINK_MODES:
                continue
            reads.add(name)
            followed += 1
            # Linux refuses a walk past 40 links. A submodule has no target.
            if self.files[name] == "160000" or followed > 40:
                return
            target = self.blob(name, self.authority)
            if target.startswith("/"):
                return
            current.pop()
            parts = [*Path(target).parts, *parts]
        reads.update(name for name in self.changed if under(name, "/".join(current) or "."))

    def cargo_reads(self, args, directory, reads):
        """Record each input in reads as the reader proves it, and the paths
        Cargo discovers in the scanned packages once the reader succeeds.
        Return the changed paths the reader judged."""
        require(args[:1] in [["test"], ["check"], ["clippy"], ["build"]],
                "unsupported-cargo-command")
        options = args[1:]
        package = None
        workspace = False
        while options:
            option, *options = options
            if option in {"-p", "--package"}:
                require(package is None and options, "unsupported-package-selector")
                package, *options = options
            elif option == "--workspace":
                workspace = True
            else:
                require(option in {"--locked", "--offline", "--all-features",
                                   "--no-default-features", "--all-targets"},
                        "unsupported-cargo-option")

        cwd = self.checkout / directory
        manifests = {}
        require(not (package and workspace), "ambiguous-cargo-package-selection")
        require(not any(re.search(r"(?:^|/)\.cargo/config(?:\.toml)?$", path)
                        for path in self.files), "cargo-config-unresolved")

        def inventory(manifest=None):
            argv = ["cargo", "metadata", "--format-version", "1", "--no-deps", "--offline", "--locked"]
            if manifest:
                argv.extend(["--manifest-path", manifest])
            found = json.loads(command(argv, cwd))
            ids = {entry["id"] for entry in found["packages"]}
            require(ids and len(ids) == len(found["packages"]) and
                    ids == set(found["workspace_members"]), "incomplete-cargo-inventory")
            root = self.relative(found["workspace_root"])
            workspace_file = "Cargo.toml" if root == "." else root + "/Cargo.toml"
            config = tomllib.loads(self.blob(workspace_file))
            require(not ({"patch", "replace"} & config.keys()), "cargo-source-overrides")
            reads.add(workspace_file)
            reads.add("Cargo.lock" if root == "." else root + "/Cargo.lock")
            for entry in found["packages"]:
                path = self.relative(entry["manifest_path"])
                self.blob(path)
                manifests[path] = entry
                reads.add(path)
            return found

        reads.update(path for path in self.changed | self.files.keys()
                     if any(part == ".cargo" for part in Path(path).parts)
                     or Path(path).name in {"rust-toolchain", "rust-toolchain.toml", "clippy.toml",
                                             ".clippy.toml"})
        found = inventory()
        defaults = set(found["workspace_default_members"])
        if not workspace and not package:
            current = command(["cargo", "locate-project", "--message-format", "plain"], cwd)
            current = self.relative(current.decode().strip())
            workspace_manifest = self.relative(Path(found["workspace_root"]) / "Cargo.toml")
            if current != workspace_manifest and current in manifests:
                defaults = {manifests[current]["id"]}
        roots = [self.relative(entry["manifest_path"]) for entry in found["packages"]
                 if (entry["name"] == package if package else
                     workspace or entry["id"] in defaults)]
        require(roots and (not package or len(roots) == 1), "cargo-package-unresolved")
        scanned = set()
        # Other evidence also lands in reads, so reads cannot mark a scan.
        scanned_sources = set()
        # Cargo discovers a build script, targets and modules by their place in
        # a package, so the reader takes a path there, which a change can add,
        # as an input it did not read.
        discovered = set()
        pending = roots[:]
        while pending:
            manifest = pending.pop()
            if manifest in scanned:
                continue
            if manifest not in manifests:
                inventory(str(self.checkout / manifest))
            entry = manifests[manifest]
            scanned.add(manifest)
            scope = Path(manifest).parent.as_posix()
            for dependency in entry["dependencies"]:
                # Cargo metadata gives a registry or Git dependency no path.
                local = dependency.get("path")
                require(isinstance(local, str), "cargo-external-dependency")
                pending.append(self.relative(Path(local) / "Cargo.toml"))
            sources = set()
            # Target auto-discovery: src/main.rs, src/bin, tests, examples and
            # benches. https://doc.rust-lang.org/cargo/reference/cargo-targets.html#target-auto-discovery
            module_roots = {(Path(scope) / name).as_posix()
                            for name in ("src", "tests", "examples", "benches")}
            require(entry["targets"], "cargo-targets-unreadable")
            for target in entry["targets"]:
                require(not ({"custom-build", "proc-macro"} & set(target["kind"])),
                        "cargo-opaque-target")
                source = self.relative(target["src_path"])
                sources.add(source)
                module_roots.add(Path(source).parent.as_posix())
                sources.update(path for path in self.files if path.endswith(".rs") and
                               under(path, Path(source).parent.as_posix()))
            target_sources = sources.copy()
            while sources:
                source = sources.pop()
                if source in scanned_sources:
                    continue
                scanned_sources.add(source)
                reads.add(source)
                rust = self.blob(source)
                # Literal includes and #[path] modules can leave the package tree.
                includes = r'\b(?:(include(?:_str|_bytes)?)\s*!\s*\(\s*|path\s*=\s*)"([^"\\]+)"'
                for macro, target in re.findall(includes, rust):
                    edge, passed = self.resolve(Path(source).parent.as_posix(), target)
                    reads.update(passed)
                    if macro in {"", "include"}:
                        require(under(edge, scope), "cargo-external-module")
                        require(edge in target_sources, "cargo-opaque-source")
                    self.blob(edge)
                    if edge.endswith(".rs"):
                        sources.add(edge)
                    else:
                        reads.add(edge)
                require(not re.search(
                    r"\b(?:include(?:_str|_bytes)?\s*!|path\s*=|(?:env|option_env)\s*!)"
                    r"|\b(?:fs|process|File|Path|PathBuf|Command|extern|unsafe)\b",
                    re.sub(includes, "", rust),
                ), "cargo-opaque-source")
            # A build.rs is discovered when the manifest sets no build key, and
            # a manifest the change adds in the tree can join the workspace.
            # https://doc.rust-lang.org/cargo/reference/manifest.html#the-build-field
            # Cargo follows a link at a target directory and finds targets
            # below it, so a path there is an input whatever its type.
            target_dirs = {(Path(scope) / name).as_posix()
                           for name in ("tests", "examples", "benches", "src/bin")}
            discovered.update(path for path in self.changed | self.files.keys() if (
                path == (Path(scope) / "build.rs").as_posix()
                or (Path(path).name == "Cargo.toml" and under(path, scope))
                or any(under(path, root) for root in target_dirs)
                or (path.endswith(".rs") and any(under(path, root) for root in module_roots))))
        reads.update(discovered)
        covered = {path for path in self.changed if any(
            under(path, Path(manifest).parent.as_posix()) for manifest in manifests
        )}
        return covered | reads

    def vitest_reads(self, directory, reads):
        """Record each input in reads as the walk proves it. Return the
        changed paths the reader judged."""
        require(self.trusted and command(["git", "rev-parse", "HEAD"], self.trusted)
                .decode().strip() == self.authority, "vitest-install-base-unavailable")
        # Vitest loads the first config it finds in its root or an ancestor,
        # which can move the root or widen discovery past it, and the reader
        # cannot rule out a test that config discovers.
        require(not any(
            Path(path).parent in {Path(directory), *Path(directory).parents}
            and Path(path).name.startswith((*VITEST_CONFIG, "vitest.workspace."))
            for path in self.files), "vitest-loaded-config")
        paths = {path for path in self.changed if self.files.get(path) in {"100644", "100755"}}
        config_dirs = set()

        def resolves_from(folder):
            # Resolution reads the package and TypeScript config files in a
            # module's directory and its ancestors, so the walk proves them as
            # it reaches the module.
            added = {folder, *folder.parents} - config_dirs
            config_dirs.update(added)
            reads.update(path for path in self.changed if Path(path).parent in added
                         and Path(path).name in JS_PACKAGES | JS_CONFIG)

        def ungraphed(path):
            # A changed file the module graph does not judge: a non-module
            # under the root, or a package file the resolution can read.
            return (under(path, directory) and not MODULE.search(path)) or (
                Path(path).parent in config_dirs and Path(path).name in JS_PACKAGES
            )

        # Vitest discovers tests and Vite its config and env files under the
        # root, and a path there the base lacks could be any of them, so each
        # changed path there is an input before any refusal. So is a config
        # an ancestor holds.
        reads.update(path for path in self.changed if under(path, directory) or (
            Path(path).parent in Path(directory).parents and Path(path).name.startswith(VITEST_CONFIG)))
        resolves_from(Path(directory))
        members = {path for path in self.files if under(path, directory)}
        for path in members:
            name = Path(path).name
            require_shape(not name.startswith((*VITEST_CONFIG, "vitest.workspace.",
                                               "tsconfig", "jsconfig", ".env")) and
                          self.files[path] in {"100644", "100755"}, "vitest-opaque-config")
        pending = {path for path in members if MODULE.search(path)}
        scanned = set()
        package_imports = set()
        while pending:
            path = pending.pop()
            if path in scanned:
                continue
            scanned.add(path)
            reads.add(path)
            parent = Path(path).parent
            resolves_from(parent)
            source = self.blob(path)
            require_shape(not re.search(
                r"\b(?:require|eval|Function|fetch|process|globalThis)\b"
                r"|\bimport\.meta|\b(?:node:|new\s+URL)|Snapshot\b|\\u", source,
            ), "vitest-opaque-source")
            for reference in JS_REFERENCE.finditer(source):
                require_shape(not reference[1], "vitest-runtime-import")
                start = reference.end()
                if source[start:start + 1] not in {"'", '"'}:
                    continue
                specifier = JS_SPECIFIER.match(source, start)
                require_shape(specifier, "vitest-computed-import")
                target = specifier[2]
                if target == "vitest":
                    # Namespace access and passed or extracted bindings can
                    # load modules without a Vitest transform edge.
                    line = source.rfind("\n", 0, reference.start()) + 1
                    named = VITEST_STATIC_IMPORT.fullmatch(source[line:reference.start()])
                    require_shape(named, "vitest-runtime-binding")
                    bindings = r"\b(?:" + "|".join(binding.strip() for binding in named[1].split(",")) + r")\b"
                    uses = source[:line] + source[specifier.end():]
                    require_shape(all(re.match(JS_TRIVIA + r"\(", uses[use.end():])
                                      for use in re.finditer(bindings, uses)), "vitest-runtime-binding")
                    continue
                require_shape(target.startswith(("./", "../")) and not re.search(r"[?#]", target),
                              "vitest-opaque-import")
                # Vite and Node resolve a relative specifier by name, so a
                # directory it passes through need not exist.
                imported, _ = self.checkout_path(parent.as_posix(), target)
                # A shape refusal keeps every module the walk resolved, and
                # the package files its resolution reads.
                reads.add(imported)
                resolves_from(Path(imported).parent)
                require_shape(imported in self.files and MODULE.search(imported),
                              "vitest-module-unresolved")
                if self.package_path(imported):
                    # Package ownership also needs imports outside Vitest's changed graph.
                    package_imports.add(imported)
                pending.add(imported)
        if any(self.package_path(path) for path in self.changed):
            require(all(self.owner(path) for path in package_imports), "vitest-import-owner-unresolved")
        # TypeScript and package resolution can read an ancestor outside
        # the Vitest root, including an ancestor of an imported module.
        require_shape(not any(
            Path(path).parent in config_dirs and Path(path).name in JS_CONFIG
            for path in self.files
        ), "vitest-inherited-config")
        # No later refusal is a shape refusal, so Vitest's related-test listing
        # alone judges a changed module the walk read.
        reads.difference_update(scanned - package_imports)
        cwd = self.checkout / directory
        upstream = self.trusted / directory / "node_modules"
        binary = upstream / ".bin/vitest"
        require(binary.is_file(), "vitest-install-unavailable")
        if not (cwd / "node_modules").is_symlink():
            (cwd / "node_modules").symlink_to(upstream, target_is_directory=True)
        paths = {path for path in paths if not ungraphed(path)}
        if not paths:
            return self.changed

        def listing(options, env=None):
            rows = json.loads(command([str(binary), "list", "--filesOnly", "--json", *options],
                                      cwd, env=env))
            require(isinstance(rows, list), "vitest-incomplete-list")
            result = {self.relative(row["file"]) for row in rows}
            require(len(result) == len(rows) and result <= members, "vitest-invalid-list")
            return result

        full = listing([])
        require(full, "vitest-no-tests")
        index = self.work / "vitest-index"
        env = {**os.environ, "GIT_INDEX_FILE": str(index)}
        command(["git", "read-tree", self.authority], self.checkout, env=env)
        names = b"".join(os.fsencode(path) + b"\0" for path in sorted(paths))
        command(["git", "update-index", "--force-remove", "-z", "--stdin"],
                self.checkout, data=names, env=env)
        # Vitest's GitVCSProvider reads line-delimited names from this index.
        # Git can still quote tabs and backslashes with quotePath disabled.
        command(["git", "config", "--local", "core.quotePath", "false"], self.checkout)
        staged = command(["git", "diff", "--cached", "--name-only"], self.checkout, env=env)
        require(set(staged.split(b"\n")[:-1]) == {os.fsencode(path) for path in paths},
                "vitest-changed-paths-unread")
        selected = listing(["--changed"], env)
        require(selected <= full and (paths & full) <= selected, "vitest-incomplete-related")
        if selected:
            reads.update(paths)
        return self.changed


def workflow_document(source):
    # BaseLoader preserves GitHub job IDs such as "on", "no" and "yes".
    import yaml

    class WorkflowLoader(yaml.BaseLoader):
        pass

    def mapping(loader, node):
        entries = loader.construct_pairs(node, deep=True)
        result = dict(entries)
        require(len(result) == len(entries) and "<<" not in result, "ambiguous-workflow")
        return result

    WorkflowLoader.add_constructor("tag:yaml.org,2002:map", mapping)
    try:
        return yaml.load(source, Loader=WorkflowLoader)
    except yaml.YAMLError as error:
        raise Unreadable("invalid-workflow") from error


def classifier_steps(jobs):
    return [(name, step) for name, job in jobs.items() for step in job.get("steps", [])
            if re.fullmatch(ACTIONS, step.get("uses", ""))]


def workflow(evidence):
    identity = os.environ.get("GITHUB_WORKFLOW_REF", "")
    if identity:
        repository = os.environ.get("GITHUB_REPOSITORY", "")
        prefix = repository + "/"
        path = identity[len(prefix):].split("@", 1)[0]
        require(repository and identity.startswith(prefix) and
                re.fullmatch(r"\.github/workflows/[^/@]+\.ya?ml", path),
                "workflow-identity-unreadable")
        if path not in evidence.files and path not in evidence.changed:
            raise SystemExit(3)
        document = workflow_document(evidence.blob(path))
        return path, document, classifier_steps(document["jobs"])
    found = []
    for path in sorted(evidence.files):
        if re.fullmatch(r"\.github/workflows/[^/]+\.ya?ml", path):
            source = evidence.blob(path)
            if ".github/actions/change-class@" not in source:
                continue
            document = workflow_document(source)
            steps = classifier_steps(document["jobs"])
            if steps:
                found.append((path, document, steps))
    require(len(found) <= 1, "workflow-identity-ambiguous")
    if not found:
        raise SystemExit(3)
    return found[0]


def references(step, key, name, output):
    return step.get(key) == "${{ steps." + name + ".outputs." + output + " }}"


def reads_lane_gate(condition):
    return re.search(r"outputs.*lane_|results.*lane_", condition)


def publishes_lanes(job):
    return any(
        key.startswith("lane_") or reads_lane_gate(value)
        for key, value in job.get("outputs", {}).items()
    ) or any(
        "lane_verdicts" in value
        for step in job.get("steps", [])
        for value in [step.get("run", ""), *step.get("env", {}).values()]
    )


def forwards_verdicts(row, classifier, job_env):
    env = row.get("env", {})
    if not references(env, "LANE_VERDICTS", classifier, "lane_verdicts"):
        return False
    lines = [line.strip() for line in row.get("run", "").strip().splitlines()]
    if not lines or not FORWARD_VERDICTS.fullmatch(lines[0]):
        return False
    if len(lines) == 1:
        return True
    narrowing = QUEUE_NARROWING.fullmatch("\n".join(lines[1:]))
    return bool(narrowing and references(env, narrowing["queue"], classifier, "queue_only") and
                env.get(narrowing["event"], job_env.get(narrowing["event"])) == "${{ github.event_name }}")


def roster(jobs, classifier, step):
    require(not os.environ.get("GITHUB_JOB") or os.environ["GITHUB_JOB"] == classifier,
            "workflow-classifier-mismatch")
    control = jobs[classifier]
    outputs = control["outputs"]
    step_id = step["id"]
    narrowed = NARROWED_LANES.fullmatch(" ".join(outputs.get("lanes", "").split()))
    require(references(outputs, "lanes", step_id, "lanes") or (
        narrowed and narrowed[3] == step_id and
        any(row.get("id") == narrowed[1] for row in control["steps"])
    ), "unmapped-lanes-output")
    emitters = [row["id"] for row in control["steps"]
                if forwards_verdicts(row, step_id, control.get("env", {}))]
    require(len(emitters) == 1, "unsupported-lanes-emitter")
    prefix = "needs." + classifier
    status = re.escape("${{ !cancelled() && ")
    fallback = re.escape("(" + prefix + ".result != 'success' || ")
    # An event test outside the fallback limits the events the job runs on.
    # It leaves what the change reaches, and so the verdict, as it is.
    event_term = r"(?:github\.event_name == '[a-z_]+' && )?"
    read_output = re.escape(prefix + ".outputs.")
    lane_output = read_output + f"lane_({LANE_ID})" + re.escape(" != 'false'")
    gate = re.compile(status + event_term + fallback + r"\(" + read_output + "lanes != 'false' && " +
                      lane_output + r"\)\) \}\}")
    scan_gate = None
    if narrowed and references(outputs, "change_class", step_id, "change_class") and references(
        outputs, "queue_deferred", emitters[0], "queue_deferred",
    ):
        flags = [key for key in outputs if re.fullmatch(OUTPUT_ID, key) and
                 references(outputs, key, narrowed[1], narrowed[2])]
        if len(flags) == 1:
            flag_output = prefix + ".outputs." + flags[0]
            scan_gate = re.compile(status + fallback + re.escape(
                f"({flag_output} == 'true' && github.event_name == 'merge_group') || "
                f"({flag_output} != 'true' && (({prefix}.outputs.change_class != 'render' && "
                f"{prefix}.outputs.queue_deferred != 'true') || "
            ) + lane_output + r"\)\)\) \}\}")
    lane_by_job = {}
    needs_by_job = {}
    scan_jobs = set()
    independent_jobs = {classifier}
    for name, job in jobs.items():
        needs = job.get("needs", [])
        if isinstance(needs, str):
            needs = [needs]
        require(isinstance(needs, list) and set(needs) <= jobs.keys(), "invalid-job-needs")
        needs_by_job[name] = needs
        condition = " ".join(job.get("if", "").split())
        if condition in {"always()", "${{ always() }}", "!cancelled()", "${{ !cancelled() }}"}:
            independent_jobs.add(name)
        match = gate.fullmatch(condition)
        if not match and scan_gate:
            match = scan_gate.fullmatch(condition)
            if match:
                scan_jobs.add(name)
        if match:
            lane = match[1]
            require(classifier in needs and references(outputs, "lane_" + lane,
                                                        emitters[0], "lane_" + lane),
                    "unmapped-lane-output")
            lane_by_job[name] = lane
        elif re.search(r"outputs.*(?:lane_|lanes)|results.*lane_", condition) or (
            classifier in needs and condition and name not in independent_jobs
        ):
            raise Unreadable("unsupported-lane-gate")
    # The workflow can close its lanes output on Markdown even when the
    # classifier has no verdicts. Each scan ancestor must stay available.
    pending = {need for name in scan_jobs for need in needs_by_job[name]}
    visited = set()
    while pending:
        job = pending.pop()
        require(job in independent_jobs, f"unsupported-scan-prerequisite job={job}")
        visited.add(job)
        pending.update(set(needs_by_job[job]) - visited)
    require(lane_by_job, "derived-lanes-absent")
    return lane_by_job, needs_by_job


def literal_job_dispatches(job):
    commands = set()
    for step in job.get("steps", []):
        for line in step.get("run", "").splitlines():
            try:
                args = words(line)
            except Unreadable:
                continue
            if lane_invocation(args) and re.fullmatch(LANE_ID, args[2]):
                commands.add(shlex.join(args))
    return sorted(commands)


def workflow_env(env):
    # Every step inherits the workflow env, and a tool can read a path a value
    # names, so each word is a path input of each step. literal() refuses an
    # absolute or home path, which can name the checkout from outside it. An
    # option word can join a path to its flag. Non-interactive bash sources the
    # one file BASH_ENV names before the step, and no other variable.
    require(isinstance(env, dict) and all(isinstance(value, str) for value in env.values()),
            "opaque-workflow-env")
    script = env.get("BASH_ENV", "")
    require(not script or (literal(script) and not script.startswith("-")),
            f"opaque-workflow-env key=BASH_ENV path={shlex.quote(script)}")
    found = [word for key, value in env.items() if key != "BASH_ENV"
             for word in re.split(r"[\s=:,;]+", value) if word]
    require(all(literal(word) and not (word.startswith("-") and re.search(r"[/.]", word))
                for word in found), "opaque-workflow-env")
    return found, script


def declared_lanes(work):
    # ci-lanes.sh is the one reader of the lane file. change-class leaves the
    # base copy here, emptied where the base declares no lane.
    declaration = work / "derived-ci-lanes.conf"
    if not declaration.read_text():
        return []
    script = '. "$1" && ci_lanes_read "$2" && printf "%s\\n" "${lane_names[@]}"'
    listed = command(["bash", "-c", script, "ci-lanes", str(Path(__file__).with_name("ci-lanes.sh")),
                      str(declaration)], work)
    return listed.decode().splitlines()


def claimed_paths(work):
    # change-class writes one LANE<TAB>PATH record per changed path a lane's
    # base claim names, each ended by NUL since a path can hold a newline.
    claimed = defaultdict(set)
    for record in (work / "lane-claims").read_text().split("\0")[:-1]:
        lane, path = record.split("\t", 1)
        claimed[lane].add(path)
    return claimed


def job_reads(evidence, job, env_words, bash_env, ordinary, readers):
    """Fill ordinary with the job's shell reads and readers with one read set
    per graph reader, so a shape refusal keeps what was proved before it.
    Return each graph reader's covered paths."""
    covered = []
    require_shape(set(job) <= {"name", "if", "needs", "runs-on", "timeout-minutes",
                              "permissions", "steps", "defaults"}, "opaque-job")
    visited = set()
    opaque_action = None
    default = job.get("defaults", {}).get("run", {})
    require_shape(set(default) <= {"shell", "working-directory"}, "unsupported-job-default")
    for step in job["steps"]:
        require_shape(set(step) <= {"id", "name", "uses", "run", "working-directory",
                                   "shell", "with", "timeout-minutes"}, "opaque-step")
        if "uses" in step:
            if not (re.fullmatch(CHECKOUT, step["uses"]) and
                    set(step.get("with", {})) <= {"persist-credentials", "fetch-depth"}):
                opaque_action = step["uses"]
            continue
        require_shape(step.get("shell", default.get("shell", "bash")) == "bash",
                      "unsupported-shell")
        directory = step.get("working-directory", default.get("working-directory", "."))
        if directory != ".":
            directory = evidence.working_directory(directory, ordinary)
        for word in env_words:
            path, passed = evidence.checkout_path(directory, word)
            ordinary.update({path} | passed)
            ordinary.update(name for name in evidence.changed if under(name, path))
        if bash_env:
            try:
                script, passed = evidence.checkout_path(directory, bash_env)
                ordinary.update({script} | passed)
                ordinary.update(name for name in evidence.changed if under(name, script))
                # bash skips a BASH_ENV file that does not exist.
                if script in evidence.files:
                    evidence.shell_reads(script, directory, ordinary, visited)
            except UNAVAILABLE as error:
                named = os.path.normpath(Path(directory) / bash_env)
                raise NamedUnreadable(
                    f"opaque-workflow-env key=BASH_ENV path={named} reason={error}", is_shape(error),
                ) from error
        for line in step["run"].splitlines():
            args = words(line)
            if not args:
                continue
            if args[0] == "cargo":
                readers.append(set())
                try:
                    covered.append(evidence.cargo_reads(args[1:], directory, readers[-1]))
                except Unreadable as error:
                    # A refusal drops every read the Cargo reader made, so no
                    # claim stands in for what it could not rule out.
                    raise Unreadable(str(error)) from error
            elif args in (["vitest", "run"], ["./node_modules/.bin/vitest", "run"],
                          ["npx", "--no-install", "vitest", "run"]):
                readers.append(set())
                covered.append(evidence.vitest_reads(directory, readers[-1]))
            else:
                evidence.shell_command(args, directory, ordinary, visited)
    require_shape(opaque_action is None, f"opaque-action action={opaque_action}")
    return covered


def derived(evidence, claimed, settings, declared):
    path, document, classifiers = workflow(evidence)
    jobs = document["jobs"]
    if not classifiers:
        raise SystemExit(3)
    advertised = any(publishes_lanes(jobs[name]) for name, _ in classifiers)
    if not advertised and not any(reads_lane_gate(job.get("if", "")) for job in jobs.values()):
        raise SystemExit(3)
    require("defaults" not in document, "opaque-workflow-defaults")
    env_words, bash_env = workflow_env(document.get("env", {}))
    require(len(classifiers) == 1, "workflow-classifier-ambiguous")
    classifier, step = classifiers[0]
    lane_by_job, needs_by_job = roster(jobs, classifier, step)
    # A declared lane that gates no job, such as one a step condition reads,
    # runs where its reasoned claims name a changed path.
    ungated = sorted(set(declared) - set(lane_by_job.values()))
    lanes = {*lane_by_job.values(), *ungated}

    def keep_prerequisites(outcomes):
        # A shared lane runs its entire group. Keep each running job's gated
        # ancestors, including dependencies through jobs without gates.
        selected = {name for name, lane in lane_by_job.items() if outcomes[lane] != "miss"}
        selected.update(name for name in jobs if name not in lane_by_job
                        and jobs[name].get("if", "") not in {"always()", "${{ always() }}"})
        visited = set()
        while selected:
            name = selected.pop()
            if name in visited:
                continue
            visited.add(name)
            for dependency in needs_by_job[name]:
                if dependency in lane_by_job:
                    outcomes[lane_by_job[dependency]] = "prerequisite"
                    selected.update(job for job, lane in lane_by_job.items()
                                    if lane == lane_by_job[dependency])
                selected.add(dependency)
        return outcomes

    require(evidence.authority == evidence.compared, "comparison-base-differs")
    require(evidence.changed, "no-changed-paths")
    authority = {path, ".github/ci-lanes.conf", "Cargo.toml", "Cargo.lock",
                 *JS_CONFIG, *JS_PACKAGES, *settings}
    if not evidence.rendered:
        authority.update({".kendex-lock.json", ".kendex-generated.json"})
    for control_step in jobs[classifier]["steps"]:
        uses = control_step.get("uses", "")
        if uses.startswith("./"):
            authority.update(name for name in evidence.changed if under(name, uses[2:]))
        for installed in re.findall(r"(?:classifier/)?(\.agents/[A-Za-z0-9_./+-]+)",
                                    control_step.get("run", "")):
            authority.add(installed)
            owner = evidence.owner(installed)
            if owner:
                authority.update(name for name in evidence.changed if evidence.owner(name) == owner)
    retain_all = dict.fromkeys(lanes, "unread")
    # Checkout attributes can change the bytes of a lane input without
    # changing its blob. Both ends of a removed or moved file are in the diff.
    if evidence.changed & authority or any(Path(name).name == ".gitattributes"
                                          for name in evidence.changed):
        return keep_prerequisites(retain_all)

    owners = {name: {evidence.owner(name)} for name in evidence.changed if evidence.package_path(name)}
    if any(None in packages for packages in owners.values()):
        return keep_prerequisites(retain_all)
    if evidence.rendered:
        for name, packages in owners.items():
            if name in evidence.proved_head_ownership:
                packages.add(evidence.proved_head_ownership[name])

    def job_reach(name, lane):
        ordinary, readers = set(), []
        try:
            covered = job_reads(evidence, jobs[name], env_words, bash_env, ordinary, readers)
            unresolved = set().union(*(evidence.changed - paths for paths in covered))
        except UNAVAILABLE as error:
            cause = str(error).splitlines()
            diagnostic = f"lane-reach: job={name} cause={cause[0] if cause else type(error).__name__}"
            if not isinstance(error, NamedUnreadable):
                diagnostic += "".join(f" command={command}" for command in literal_job_dispatches(jobs[name]))
            print(diagnostic, file=sys.stderr)
            if not is_shape(error):
                return set(), evidence.changed
            # The lane's reasoned claims name what the reader misses in this
            # shape, and the reads proved before the refusal still reach the
            # job. A lane with no claim could read any changed path.
            unresolved = set() if lane in declared else evidence.changed
        reads = ordinary.union(*readers)
        packages = {evidence.owner(path) for path in reads} - {None}
        hits = (reads & evidence.changed) | {
            rendered_path for rendered_path, package_owners in owners.items()
            if packages & package_owners
        }
        return hits, unresolved

    # A changed path that several lanes read or claim reaches each of them
    # through its own hits, so it runs those lanes and no other. A path a
    # lane's reader could not rule out, where another lane reaches it too,
    # keeps every lane.
    reached = defaultdict(set)
    unread = set()
    outcomes = dict.fromkeys(lanes, "miss")
    for name, lane in [*lane_by_job.items(), *((None, lane) for lane in ungated)]:
        hits, unresolved = job_reach(name, lane) if name is not None else (set(), set())
        # A reasoned claim adds the changed paths it names to what the job reads.
        hits |= claimed.get(lane, set())
        for path in hits | unresolved:
            reached[path].add(lane)
        unread |= unresolved
        if unresolved:
            outcomes[lane] = "unread"
        elif hits and outcomes[lane] == "miss":
            outcomes[lane] = "hit"
    shared_unread = any(len(reached[path]) > 1 for path in unread)
    return keep_prerequisites(retain_all if shared_unread else outcomes)


def trusted_push(authority, head):
    # The runner's push payload binds the default branch and both endpoints.
    # A feature-branch parent must never become an executable graph input.
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        branch = event["repository"]["default_branch"]
        return bool(branch and event["ref"] == "refs/heads/" + branch and
                    os.environ["GITHUB_REF"] == event["ref"] and event["forced"] is False and
                    event["before"] == authority and event["after"] == head)
    except UNAVAILABLE:
        return False


def main():
    repo, authority, compared, head, work, trusted, rendered, settings, event = sys.argv[1:]
    if event == "push" and not trusted_push(authority, head):
        return 3
    try:
        evidence = Evidence(repo, authority, compared, head, work, trusted, rendered == "render")
        claimed = claimed_paths(Path(work))
        declared = declared_lanes(Path(work))
        for name, result in sorted(derived(evidence, claimed, settings.split(), declared).items()):
            print(f"{name}\t{result}")
    except (*UNAVAILABLE, ImportError) as error:
        cause = str(error).splitlines()
        print(f"lane-reach: cause={cause[0] if cause else type(error).__name__}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
