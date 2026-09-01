"""The command line: `render`, `check`, `adopt`."""

import argparse
import os
import sys

from .errors import BotInstructionsError, ValidationFailed
from . import run, tree, verbs

SPEC_FILES = ("SKILL.md", "schemas/renders.md")


def parser():
    p = argparse.ArgumentParser(
        prog="bot-instructions",
        description="Render every review bot's instruction file from one doctrine "
                    "source plus bot-instructions.toml.",
    )
    p.add_argument("verb", choices=("render", "check", "adopt"))
    p.add_argument("--repo", default=".", help="repo root (default: the working directory)")
    p.add_argument(
        "--spec",
        default=None,
        help="a copy of this package to read doctrine and the routing table from. "
             "Defaults to the running copy. In CI, point the trusted default-branch "
             "checkout at the pull request's tree with this.",
    )
    p.add_argument(
        "--staged",
        action="store_true",
        help="read the index rather than the working tree, for every render input as "
             "well as the outputs, so a pre-commit lane judges one coherent state",
    )
    p.add_argument("--dry-run", action="store_true", help="render: validate and write nothing")
    return p


def running_copy():
    """The package root: this file is `<root>/scripts/lib/cli.py`."""
    here = os.path.realpath(__file__)
    return os.path.dirname(os.path.dirname(os.path.dirname(here)))


def _spec_source(repo, spec_root, work, staged):
    """Where the spec copy is read from, and at which paths.

    Under `--staged` a spec copy that lives inside the repo is read from the
    index like every other render input, or an unstaged doctrine edit decides
    what the staged outputs are compared against.

    Inside is a question about path COMPONENTS, never about characters:
    `<repo>/..spec` is inside the repo and its relative path opens with those
    two bytes. `relpath` leaves an escape as a leading `..` component.
    """
    inside = os.path.relpath(spec_root, repo)
    if staged and inside.split(os.sep)[0] != os.pardir:
        prefix = "" if inside == os.curdir else inside + "/"
        return work, tuple(prefix + name for name in SPEC_FILES)
    return tree.Worktree(spec_root), SPEC_FILES


def main(argv=None):
    args = parser().parse_args(argv)
    if args.staged and args.verb != "check":
        print("--staged is a check mode; render and adopt write the working tree",
              file=sys.stderr)
        return 2
    if args.dry_run and args.verb != "render":
        # `adopt` is the one-time verb that writes, so a flag it accepted and
        # ignored would take the files over on a run meant to preview.
        print(f"--dry-run is a render mode; {args.verb} does not write a set to preview",
              file=sys.stderr)
        return 2
    # The two roots an operator names are resolved through their symlinks
    # once, here. Containment is about not escaping the resolved root, never
    # about how the operator spelled it, and in a kendex-installed repo the
    # documented `--spec` value is `.agents/skills/bot-instructions`, which is
    # a symlink to the package: the no-follow walk below that root would
    # otherwise refuse the root itself.
    repo = os.path.realpath(args.repo)
    spec_root = os.path.realpath(args.spec) if args.spec else running_copy()
    try:
        work = tree.open_tree(repo, args.staged)
        spec_tree, spec_paths = _spec_source(repo, spec_root, work, args.staged)
        ctx = run.Context(repo, work, spec_tree, spec_paths,
                          "render" if args.verb == "render" else "check",
                          spec_names=SPEC_FILES)
        if args.verb == "render":
            lines = verbs.render_verb(ctx, repo, dry_run=args.dry_run)
        elif args.verb == "check":
            lines = verbs.check_verb(ctx)
        else:
            lines = verbs.adopt_verb(ctx, repo)
    except ValidationFailed as exc:
        for finding in exc.findings:
            print(finding, file=sys.stderr)
        print(f"{len(exc.findings)} finding(s)", file=sys.stderr)
        return 1
    except BotInstructionsError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    for line in lines:
        print(line)
    return 0
