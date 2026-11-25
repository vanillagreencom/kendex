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
    pass


class UnresolvedDispatch(Unreadable):
    pass


def require(condition, cause):
    if not condition:
        raise Unreadable(cause)


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
    tokens = shlex.split(line)
    require(all(literal(word) or word == ":" for word in tokens), "computed-command")
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
JS_PACKAGES = {"package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"}
CHECKOUT = r"actions/checkout@[^\s]+"
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


def lane_table(lines, lane):
    end = len(lines) - len(LANE_TABLE_DISPATCH)
    require(end > 0 and lines[end:] == LANE_TABLE_DISPATCH and
            lines[0] == "lane_table=(", "unsupported-runner-dispatch")
    index = 1
    members = {}
    while index < end and lines[index] != ")":
        entry = re.fullmatch(rf'"({LANE_ID}):', lines[index])
        require(entry and entry[1] not in members, "unsupported-runner-table")
        close = lines.index('"', index + 1, end)
        selected = []
        for row in lines[index + 1:close]:
            if re.fullmatch(r"@[A-Za-z0-9_./+*?-]+|\+(?:host|isolated)", row):
                continue
            require(re.fullmatch(LANE_ID, row), "unsupported-runner-member")
            selected.append(row)
        members[entry[1]] = selected
        index = close + 1
    require(index < end and lane in members and members[lane], "runner-lane-unresolved")
    index += 1
    functions = {}
    while index < end:
        definition = re.fullmatch(r"(step_[a-z0-9_]+)\(\) \{", lines[index])
        require(definition and definition[1] not in functions, "unsupported-runner-function")
        close = lines.index("}", index + 1, end)
        body = [args for line in lines[index + 1:close] if (args := words(line))]
        require(body and all(args[0] not in SHELL_KEYWORDS for args in body),
                "unsupported-runner-body")
        functions[definition[1]] = body
        index = close + 1
    return members[lane], functions


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
            require(self.files.get(path) in {"100644", "100755"}, "non-regular-input")
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
            reads.update(passed)
            invocation = (script, directory, lane)
            if invocation in visited:
                return
            visited.add(invocation)
            body = self.blob(script).split("\n")
            require(self.files[script] == "100755" and body[:1] in BASH_SHEBANGS,
                    "unsupported-runner-interpreter")
            lines = [line.strip(" \t") for line in body[1:] if line.strip(" \t")]
            if lines[:1] in STRICT_MODE:
                lines = lines[1:]
            members, functions = lane_table(lines, lane)
            reads.add(script)
            for member in members:
                step = "step_" + member.replace("-", "_")
                require(step in functions, f"runner-step-unresolved step={step}")
                for command in functions[step]:
                    self.shell_command(command, directory, reads, visited)
        except UNAVAILABLE as error:
            raise UnresolvedDispatch(
                f"unresolved-lane-dispatch command={shlex.join(args)} reason={error}"
            ) from error

    def shell_command(self, args, directory, reads, visited):
        name, *operands = args
        if name in {"source", ".", "bash"} and len(operands) == 1:
            require(name == "bash" or "/" in operands[0], "shell-source-uses-path")
            script, passed = self.resolve(directory, operands[0])
            reads.update(passed)
            self.shell_reads(script, directory, reads, visited)
        elif lane_invocation(args):
            require(re.fullmatch(LANE_ID, operands[1]), "invalid-runner-lane")
            self.lane_dispatch(args, directory, reads, visited)
        elif name.startswith("./") and not operands:
            script, passed = self.resolve(directory, name)
            reads.update(passed)
            require(self.files.get(script) == "100755" and self.blob(script).splitlines()[:1]
                    in [*BASH_SHEBANGS, ["#!/bin/sh"]],
                    "unsupported-script-interpreter")
            self.shell_reads(script, directory, reads, visited)
        elif name == "cat" and operands and all(literal(path) for path in operands):
            for path in operands:
                path, passed = self.resolve(directory, path)
                reads.update({path} | passed)
        elif name == "test":
            require(len(operands) == 2 and operands[0] in {"-f", "-r", "-e"},
                    "unsupported-shell-test")
            path, passed = self.resolve(directory, operands[1])
            reads.update({path} | passed)
            reads.update(name for name in self.changed if under(name, path))
        elif name == "set" and operands in [["-euo", "pipefail"], ["-eu"]]:
            return
        else:
            require(name in {":", "true", "false"} and not operands, "opaque-shell-command")

    def resolve(self, directory, path):
        require(literal(path) and not path.startswith("-"), "computed-path")
        return self.checkout_path(directory, path)

    def checkout_path(self, directory, path):
        original = Path(directory) / path
        prefixes = [os.path.normpath(prefix) for prefix in original.parents]
        # Check each original prefix before a later '..' can hide a link.
        for prefix in (os.path.normpath(original), *prefixes):
            require(self.files.get(prefix) not in {"120000", "160000"}, "indirect-path")
        result = os.path.normpath(original)
        require(result not in {"..", "."} and not result.startswith("../"), "path-outside-repo")
        # A kernel walk must enter each directory the path names before a
        # later '..' leaves it, and the result's own existence does not prove
        # that directory exists. The starting directory has its own evidence.
        # The changed paths under those directories are returned apart, for
        # the readers whose tool walks the path that way.
        passed = {name for prefix in prefixes[:len(Path(path).parts) - 1]
                  if not under(result, prefix)
                  for name in self.changed if under(name, prefix)}
        return result, passed

    def cargo_reads(self, args, directory):
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

        reads = {path for path in self.changed | self.files.keys()
                 if any(part == ".cargo" for part in Path(path).parts)
                 or Path(path).name in {"rust-toolchain", "rust-toolchain.toml", "clippy.toml",
                                         ".clippy.toml"}}
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
                local = dependency["path"]
                require(isinstance(local, str), "cargo-external-dependency")
                pending.append(self.relative(Path(local) / "Cargo.toml"))
            sources = set()
            require(entry["targets"], "cargo-targets-unreadable")
            for target in entry["targets"]:
                require(not ({"custom-build", "proc-macro"} & set(target["kind"])),
                        "cargo-opaque-target")
                source = self.relative(target["src_path"])
                sources.add(source)
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
            reads.update(path for path in self.changed | self.files.keys() if under(path, scope))
        covered = {path for path in self.changed if any(
            under(path, Path(manifest).parent.as_posix()) for manifest in manifests
        )}
        return reads, covered | reads

    def vitest_reads(self, directory):
        require(self.trusted and command(["git", "rev-parse", "HEAD"], self.trusted)
                .decode().strip() == self.authority, "vitest-install-base-unavailable")
        members = {path for path in self.files if under(path, directory)}
        for path in members:
            name = Path(path).name
            require(not name.startswith(("vitest.config.", "vite.config.", "vitest.workspace.",
                                         "tsconfig", "jsconfig", ".env")) and
                    self.files[path] in {"100644", "100755"}, "vitest-opaque-config")
        pending = {path for path in members if MODULE.search(path)}
        scanned = set()
        package_imports = set()
        config_dirs = {Path(directory), *Path(directory).parents}
        while pending:
            path = pending.pop()
            if path in scanned:
                continue
            scanned.add(path)
            parent = Path(path).parent
            config_dirs.update((parent, *parent.parents))
            source = self.blob(path)
            require(not re.search(
                r"\b(?:require|eval|Function|fetch|process|globalThis)\b"
                r"|\bimport\.meta|\b(?:node:|new\s+URL)|Snapshot\b|\\u", source,
            ), "vitest-opaque-source")
            for reference in JS_REFERENCE.finditer(source):
                require(not reference[1], "vitest-runtime-import")
                start = reference.end()
                if source[start:start + 1] not in {"'", '"'}:
                    continue
                specifier = JS_SPECIFIER.match(source, start)
                require(specifier, "vitest-computed-import")
                target = specifier[2]
                if target == "vitest":
                    # Namespace access and passed or extracted bindings can
                    # load modules without a Vitest transform edge.
                    line = source.rfind("\n", 0, reference.start()) + 1
                    named = VITEST_STATIC_IMPORT.fullmatch(source[line:reference.start()])
                    require(named, "vitest-runtime-binding")
                    bindings = r"\b(?:" + "|".join(binding.strip() for binding in named[1].split(",")) + r")\b"
                    uses = source[:line] + source[specifier.end():]
                    require(all(re.match(JS_TRIVIA + r"\(", uses[use.end():])
                                for use in re.finditer(bindings, uses)), "vitest-runtime-binding")
                    continue
                require(target.startswith(("./", "../")) and not re.search(r"[?#]", target),
                        "vitest-opaque-import")
                # Vite and Node resolve a relative specifier by name, so a
                # directory it passes through need not exist.
                imported, _ = self.checkout_path(parent.as_posix(), target)
                require(imported in self.files and MODULE.search(imported), "vitest-module-unresolved")
                if self.package_path(imported):
                    package_imports.add(imported)
                pending.add(imported)
        if any(self.package_path(path) for path in self.changed):
            require(all(self.owner(path) for path in package_imports), "vitest-import-owner-unresolved")
        # TypeScript and package resolution can read an ancestor outside
        # the Vitest root, including an ancestor of an imported module.
        require(not any(
            Path(path).parent in config_dirs and Path(path).name in JS_CONFIG
            for path in self.files
        ), "vitest-inherited-config")
        cwd = self.checkout / directory
        upstream = self.trusted / directory / "node_modules"
        binary = upstream / ".bin/vitest"
        require(binary.is_file(), "vitest-install-unavailable")
        if not (cwd / "node_modules").is_symlink():
            (cwd / "node_modules").symlink_to(upstream, target_is_directory=True)
        paths = {path for path in self.changed if self.files.get(path) in {"100644", "100755"}}
        reads = (self.changed - paths) | {
            path for path in paths if (
                under(path, directory) and not MODULE.search(path)
            ) or (
                Path(path).parent in config_dirs and Path(path).name in JS_PACKAGES
            )
        }
        paths -= reads
        # Package ownership also needs imports outside Vitest's changed graph.
        reads.update(package_imports)
        if not paths:
            return reads, self.changed

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
        return reads | (paths if selected else set()), self.changed


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
    fallback = re.escape("${{ !cancelled() && (" + prefix + ".result != 'success' || ")
    read_output = re.escape(prefix + ".outputs.")
    lane_output = read_output + f"lane_({LANE_ID})" + re.escape(" != 'false'")
    gate = re.compile(fallback + r"\(" + read_output + "lanes != 'false' && " +
                      lane_output + r"\)\) \}\}")
    scan_gate = None
    if narrowed and references(outputs, "change_class", step_id, "change_class") and references(
        outputs, "queue_deferred", emitters[0], "queue_deferred",
    ):
        flags = [key for key in outputs if re.fullmatch(OUTPUT_ID, key) and
                 references(outputs, key, narrowed[1], narrowed[2])]
        if len(flags) == 1:
            flag_output = prefix + ".outputs." + flags[0]
            scan_gate = re.compile(fallback + re.escape(
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
            except (Unreadable, ValueError):
                continue
            if lane_invocation(args) and re.fullmatch(LANE_ID, args[2]):
                commands.add(shlex.join(args))
    return sorted(commands)


def job_reads(evidence, job):
    require(set(job) <= {"name", "if", "needs", "runs-on", "timeout-minutes",
                        "permissions", "steps", "defaults"}, "opaque-job")
    ordinary = set()
    visited = set()
    readers = []
    opaque_action = None
    default = job.get("defaults", {}).get("run", {})
    require(set(default) <= {"shell", "working-directory"}, "unsupported-job-default")
    for step in job["steps"]:
        require(set(step) <= {"id", "name", "uses", "run", "working-directory",
                             "shell", "with", "timeout-minutes"}, "opaque-step")
        if "uses" in step:
            if not (re.fullmatch(CHECKOUT, step["uses"]) and
                    set(step.get("with", {})) <= {"persist-credentials", "fetch-depth"}):
                opaque_action = step["uses"]
            continue
        require(step.get("shell", default.get("shell", "bash")) == "bash",
                "unsupported-shell")
        directory = step.get("working-directory", default.get("working-directory", "."))
        if directory != ".":
            directory, passed = evidence.resolve(".", directory)
            ordinary.update(passed)
            # A checkout materializes directories through their tracked entries.
            require(evidence.git("ls-tree", "-rz", evidence.head, "--", directory + "/"),
                    "working-directory-unproved")
        for line in step["run"].splitlines():
            args = words(line)
            if not args:
                continue
            if args[0] == "cargo":
                readers.append(evidence.cargo_reads(args[1:], directory))
            elif args in (["vitest", "run"], ["./node_modules/.bin/vitest", "run"],
                          ["npx", "--no-install", "vitest", "run"]):
                readers.append(evidence.vitest_reads(directory))
            else:
                evidence.shell_command(args, directory, ordinary, visited)
    require(opaque_action is None, f"opaque-action action={opaque_action}")
    return ordinary, readers


def derived(evidence, exceptions, settings):
    path, document, classifiers = workflow(evidence)
    jobs = document["jobs"]
    if not classifiers:
        raise SystemExit(3)
    advertised = any(publishes_lanes(jobs[name]) for name, _ in classifiers)
    if not advertised and not any(reads_lane_gate(job.get("if", "")) for job in jobs.values()):
        raise SystemExit(3)
    require(not ({"defaults", "env"} & document.keys()), "opaque-workflow-defaults")
    require(len(classifiers) == 1, "workflow-classifier-ambiguous")
    classifier, step = classifiers[0]
    lane_by_job, needs_by_job = roster(jobs, classifier, step)

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
    retain_all = dict.fromkeys(lane_by_job.values(), "unread")
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

    first_reader = {}
    shared_input = False
    outcomes = dict.fromkeys(lane_by_job.values(), "miss")
    for name, lane in lane_by_job.items():
        try:
            ordinary, readers = job_reads(evidence, jobs[name])
            reads = ordinary | set().union(*(read for read, _ in readers))
            packages = {evidence.owner(path) for path in reads} - {None}
            hits = (reads & evidence.changed) | {
                rendered_path for rendered_path, package_owners in owners.items()
                if packages & package_owners
            }
            unresolved = set().union(*(evidence.changed - covered for _, covered in readers))
        except UNAVAILABLE as error:
            cause = str(error).splitlines()
            diagnostic = f"lane-reach: job={name} cause={cause[0] if cause else type(error).__name__}"
            if not isinstance(error, UnresolvedDispatch):
                diagnostic += "".join(f" command={command}" for command in literal_job_dispatches(jobs[name]))
            print(diagnostic, file=sys.stderr)
            hits, unresolved = set(), evidence.changed
        if lane in exceptions:
            # The legacy claim pass gives us lane names across the diff.
            hits = evidence.changed
        if any(first_reader.setdefault(path, lane) != lane for path in hits | unresolved):
            # Later jobs can still supply the cause of an unresolved dispatch.
            shared_input = True
        if unresolved:
            outcomes[lane] = "unread"
        elif hits and outcomes[lane] == "miss":
            outcomes[lane] = "hit"
    return keep_prerequisites(retain_all if shared_input else outcomes)


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
        exceptions = set((Path(work) / "lane-exceptions").read_text().splitlines())
        for name, result in sorted(derived(evidence, exceptions, settings.split()).items()):
            print(f"{name}\t{result}")
    except (*UNAVAILABLE, ImportError) as error:
        cause = str(error).splitlines()
        print(f"lane-reach: cause={cause[0] if cause else type(error).__name__}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
