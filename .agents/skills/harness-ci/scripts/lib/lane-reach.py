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


ACTIONS = r"vanillagreencom/kendex/\.github/actions/change-class@[^\s]+"
LANE_ID = r"[a-z0-9][a-z0-9_-]*"
RENDER = (".agents/", ".claude/", ".codex/", ".pi/")
MODULE = re.compile(r"\.(?:[cm]?[jt]s|[jt]sx)$")
CHECKOUT = r"actions/checkout@[^\s]+"
UNAVAILABLE = (Unreadable, OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired)


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
            inventory = {
                row if isinstance(row, str) else row["path"] for row in inventory
            }
            owners = defaultdict(set)
            for entry in entries.values():
                if not entry["enabled"]:
                    continue
                emitted = entry["emitted"]
                package = (entry["sourceRepo"], emitted["kind"], emitted["name"])
                for path in inventory:
                    if path.startswith(RENDER) and any(
                        under(path, position) for position in emitted["paths"]
                    ):
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

    def shell_reads(self, script, directory, reads):
        if script in reads:
            return
        reads.add(script)
        for line in self.blob(script).splitlines():
            args = words(line)
            if args:
                self.shell_command(args, directory, reads)

    def shell_command(self, args, directory, reads):
        name, *operands = args
        if name in {"source", ".", "bash"} and len(operands) == 1:
            require(name == "bash" or "/" in operands[0], "shell-source-uses-path")
            self.shell_reads(self.resolve(directory, operands[0]), directory, reads)
        elif name.startswith("./") and not operands:
            script = self.resolve(directory, name)
            require(self.files.get(script) == "100755" and self.blob(script).splitlines()[:1]
                    in [["#!/usr/bin/env bash"], ["#!/bin/bash"], ["#!/bin/sh"]],
                    "unsupported-script-interpreter")
            self.shell_reads(script, directory, reads)
        elif name == "cat" and operands and all(literal(path) for path in operands):
            for path in operands:
                reads.add(self.resolve(directory, path))
        elif name == "test":
            require(len(operands) == 2 and operands[0] in {"-f", "-r", "-e"},
                    "unsupported-shell-test")
            path = self.resolve(directory, operands[1])
            reads.add(path)
            reads.update(name for name in self.changed if under(name, path))
        elif name == "set" and operands in [["-euo", "pipefail"], ["-eu"]]:
            return
        else:
            require(name in {":", "true", "false"} and not operands, "opaque-shell-command")

    def resolve(self, directory, path):
        require(literal(path) and not path.startswith("-"), "computed-path")
        result = os.path.normpath(os.path.join(directory, path))
        require(result not in {"..", "."} and not result.startswith("../"), "path-outside-repo")
        for parent in (Path(result), *Path(result).parents):
            require(self.files.get(parent.as_posix()) not in {"120000", "160000"},
                    "indirect-path")
        return result

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
            while sources:
                source = sources.pop()
                if source in reads:
                    continue
                reads.add(source)
                rust = self.blob(source)
                # Literal includes and #[path] modules can leave the package tree.
                includes = r'(?:\binclude(?:_str|_bytes)?\s*!\s*\(\s*|\bpath\s*=\s*)"([^"\\]+)"'
                for target in re.findall(includes, rust):
                    edge = self.resolve(Path(source).parent.as_posix(), target)
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
        placed = {path for path in self.changed if any(
            under(path, Path(manifest).parent.as_posix()) for manifest in manifests
        )}
        return reads, placed

    def vitest_reads(self, directory):
        require(self.trusted and command(["git", "rev-parse", "HEAD"], self.trusted)
                .decode().strip() == self.authority, "vitest-install-base-unavailable")
        members = {path for path in self.files if under(path, directory)}
        relevant = {path for path in self.changed if under(path, directory)}
        for path in members:
            name = Path(path).name
            require(not name.startswith(("vitest.config.", "vite.config.", "vitest.workspace.",
                                         "tsconfig", "jsconfig", ".env")) and
                    self.files[path] in {"100644", "100755"}, "vitest-opaque-config")
            if MODULE.search(path):
                source = self.blob(path)
                require(not re.search(
                    r"\b(?:require|eval|Function|fetch|process|globalThis|vi\.(?:mock|stub\w*))\b"
                    r"|\bimport\s*\(\s*[^'\"\s]|\bimport\.meta|\b(?:node:|new\s+URL)"
                    r"|Snapshot\b", source,
                ), "vitest-opaque-source")
                for specifier in re.findall(
                    r"\b(?:from\s+|import\s*(?:\(\s*)?)['\"]([^'\"]+)['\"]", source,
                ):
                    if specifier == "vitest":
                        continue
                    require(specifier.startswith(("./", "../")) and
                            under(self.resolve(Path(path).parent.as_posix(), specifier), directory),
                            "vitest-import-outside-project")
        cwd = self.checkout / directory
        upstream = self.trusted / directory / "node_modules"
        binary = upstream / ".bin/vitest"
        require(binary.is_file(), "vitest-install-unavailable")
        if not (cwd / "node_modules").is_symlink():
            (cwd / "node_modules").symlink_to(upstream, target_is_directory=True)
        reads = relevant - {path for path in relevant & members if MODULE.search(path)}
        paths = relevant - reads
        if not paths:
            return reads, relevant

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
        staged = command(["git", "diff", "--cached", "--name-only", "-z"], self.checkout, env=env)
        require(set(staged.split(b"\0")) == set(names.split(b"\0")), "vitest-changed-paths-unread")
        selected = listing(["--changed"], env)
        require(selected <= full and (paths & full) <= selected, "vitest-incomplete-related")
        return reads | (paths if selected else set()), relevant


def yaml_jobs(source):
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
        document = yaml.load(source, Loader=WorkflowLoader)
        require(not ({"defaults", "env"} & document.keys()), "opaque-workflow-defaults")
        return document["jobs"]
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
        jobs = yaml_jobs(evidence.blob(path))
        return path, jobs, classifier_steps(jobs)
    found = []
    for path in sorted(evidence.files):
        if re.fullmatch(r"\.github/workflows/[^/]+\.ya?ml", path):
            source = evidence.blob(path)
            if ".github/actions/change-class@" not in source:
                continue
            jobs = yaml_jobs(source)
            steps = classifier_steps(jobs)
            if steps:
                found.append((path, jobs, steps))
    require(len(found) <= 1, "workflow-identity-ambiguous")
    if not found:
        raise SystemExit(3)
    return found[0]


def references(step, key, name, output):
    return step.get(key) == "${{ steps." + name + ".outputs." + output + " }}"


def roster(jobs, classifier, step):
    require(not os.environ.get("GITHUB_JOB") or os.environ["GITHUB_JOB"] == classifier,
            "workflow-classifier-mismatch")
    control = jobs[classifier]
    outputs = control["outputs"]
    step_id = step["id"]
    require(references(outputs, "lanes", step_id, "lanes"), "unmapped-lanes-output")
    emitters = [
        row["id"] for row in control["steps"]
        if row.get("run", "").strip() == """printf '%s\\n' "$LANE_VERDICTS" >>"$GITHUB_OUTPUT" """
        .strip() and references(row.get("env", {}), "LANE_VERDICTS", step_id, "lane_verdicts")
    ]
    require(len(emitters) == 1, "unsupported-lanes-emitter")
    prefix = "needs." + classifier
    gate = re.compile(re.escape(
        "${{ !cancelled() && (" + prefix + ".result != 'success' || (" + prefix +
        ".outputs.lanes != 'false' && " + prefix + ".outputs.lane_"
    ) + f"({LANE_ID})" + re.escape(" != 'false')) }}"))
    lane_by_job = {}
    needs_by_job = {}
    for name, job in jobs.items():
        needs = job.get("needs", [])
        if isinstance(needs, str):
            needs = [needs]
        require(isinstance(needs, list) and set(needs) <= jobs.keys(), "invalid-job-needs")
        needs_by_job[name] = needs
        condition = " ".join(job.get("if", "").split())
        match = gate.fullmatch(condition)
        if match:
            lane = match[1]
            require(classifier in needs and references(outputs, "lane_" + lane,
                                                        emitters[0], "lane_" + lane),
                    "unmapped-lane-output")
            lane_by_job[name] = lane
        elif re.search(r"outputs.*(?:lane_|lanes)|results.*lane_", condition) or (
            classifier in needs and condition not in {"", "always()", "${{ always() }}"}
        ):
            raise Unreadable("unsupported-lane-gate")
    require(lane_by_job, "derived-lanes-absent")
    return lane_by_job, needs_by_job


def job_reads(evidence, job):
    require(set(job) <= {"name", "if", "needs", "runs-on", "timeout-minutes",
                        "permissions", "steps", "defaults"}, "opaque-job")
    ordinary = set()
    readers = []
    default = job.get("defaults", {}).get("run", {})
    require(set(default) <= {"shell", "working-directory"}, "unsupported-job-default")
    for step in job["steps"]:
        require(set(step) <= {"id", "name", "uses", "run", "working-directory",
                             "shell", "with", "timeout-minutes"}, "opaque-step")
        if "uses" in step:
            require(re.fullmatch(CHECKOUT, step["uses"]) and
                    set(step.get("with", {})) <= {"persist-credentials", "fetch-depth"},
                    "opaque-action")
            continue
        require(step.get("shell", default.get("shell", "bash")) == "bash",
                "unsupported-shell")
        directory = step.get("working-directory", default.get("working-directory", "."))
        if directory != ".":
            directory = evidence.resolve(".", directory)
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
                evidence.shell_command(args, directory, ordinary)
    return ordinary, readers


def derived(evidence, exceptions, settings):
    path, jobs, classifiers = workflow(evidence)
    if not classifiers:
        raise SystemExit(3)
    require(len(classifiers) == 1, "workflow-classifier-ambiguous")
    classifier, step = classifiers[0]
    lane_by_job, needs_by_job = roster(jobs, classifier, step)
    require(evidence.authority == evidence.compared, "comparison-base-differs")
    require(evidence.changed, "no-changed-paths")
    authority = {path, ".github/ci-lanes.conf", *settings}
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
    outcomes = dict.fromkeys(lane_by_job.values(), "unread")
    if evidence.changed & authority:
        return outcomes

    job_evidence = {}
    placed = set()
    for name in lane_by_job:
        try:
            ordinary, readers = job_reads(evidence, jobs[name])
            reads = ordinary | set().union(*(read for read, _ in readers))
            packages = {evidence.owner(path) for path in reads if path.startswith(RENDER)} - {None}
            job_evidence[name] = (reads, packages, bool(readers))
            placed.update(reads)
            placed.update(set().union(*(known for _, known in readers)))
        except UNAVAILABLE as error:
            print(f"lane-reach: job={name} cause={str(error).splitlines()[0]}", file=sys.stderr)

    owners = {name: evidence.owner(name) for name in evidence.changed if name.startswith(RENDER)}
    installed = set(owners.values()) - {None}
    if evidence.rendered:
        installed.update(evidence.proved_head_ownership[name] for name in owners
                         if name in evidence.proved_head_ownership)
    unowned = {name for name, owner in owners.items() if owner is None}
    unknown = evidence.changed - placed - owners.keys()
    selected = set()
    outcomes = dict.fromkeys(lane_by_job.values(), "miss")
    for name, lane in lane_by_job.items():
        if name not in job_evidence or unowned:
            outcomes[lane] = "unread"
            selected.add(name)
            continue
        reads, packages, graph = job_evidence[name]
        if graph and unknown:
            outcomes[lane] = "unread"
            selected.add(name)
        elif lane in exceptions or evidence.changed & reads or packages & installed:
            if outcomes[lane] == "miss":
                outcomes[lane] = "hit"
            selected.add(name)
    # A shared lane runs its entire group. Keep each running job's gated
    # ancestors, including dependencies through jobs without gates.
    selected.update(name for name, lane in lane_by_job.items() if outcomes[lane] != "miss")
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


def main():
    repo, authority, compared, head, work, trusted, rendered, settings = sys.argv[1:]
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
