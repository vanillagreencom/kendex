"""The command line: `render`, `check`, `adopt`, `retire`, `region-bounds`.

Output protocol, which the commit-guards pre-commit lane and this package's
suites read:

    refusal   bot-instructions: key=value   first line, on stderr, exit 2
    findings  bot-instructions: findings=N  first line, on stderr, exit 1
              then one line per finding
    bounds    region bounds<TAB>start<TAB>end   `region-bounds`, stdout, exit 0

The key names the condition and the value is that condition's subject: the
repository or spec root for a failure reading them, the argument for a usage
refusal, the interpreter for a launcher refusal, the count for findings, and
the `--input` path for `region-bounds`. It is not always a path.

`region-input` is the one subject a person cannot open: the host writes the
snapshot to a temporary file and unlinks it as soon as the child returns. The
English below that record therefore carries the file the region lives in and
the heading count, and the host prefixes its own path and the snapshot it was
reading. The English that follows either record is for a person and carries no
contract. Exit codes: 0 clean, 1 findings, 2 could not complete.
"""

import argparse
import os
import sys
import traceback

from .errors import BotInstructionsError, SpecError, ValidationFailed
from . import render, run, tree, verbs

SPEC_FILES = ("SKILL.md", "schemas/renders.md")


class _Parser(argparse.ArgumentParser):
    """Argparse exits on its own, before `main` can catch anything, so it
    writes the record itself. Its subject is the argument the caller gave,
    which is what they have to change."""

    given = ()

    def error(self, message):
        # The arguments this parse was handed, not the process's own: `main`
        # may be called with an explicit list, and the offending token is not
        # always the first one.
        shown = " ".join(self.given) if self.given else "(none)"
        print(f"bot-instructions: usage={shown}", file=sys.stderr)
        print(message, file=sys.stderr)
        raise SystemExit(2)


def parser():
    p = _Parser(
        prog="bot-instructions",
        description="Render every review bot's instruction file from one doctrine "
                    "source plus [bot-instructions].",
    )
    p.add_argument("verb", choices=("render", "check", "adopt", "retire", "region-bounds"))
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
    p.add_argument("--input", default=None, help=argparse.SUPPRESS)
    return p


def running_copy():
    """The package root: this file is `<root>/scripts/lib/cli.py`."""
    here = os.path.realpath(__file__)
    return os.path.dirname(os.path.dirname(os.path.dirname(here)))


def _region_bounds(path):
    """Report the package-owned body span for one host-supplied snapshot."""
    try:
        with open(path, encoding="utf-8", newline="") as source:
            text = source.read()
    except (OSError, UnicodeError) as exc:
        print(f"bot-instructions: region-input={path}", file=sys.stderr)
        print(exc, file=sys.stderr)
        return 2
    span = render.body_byte_bounds(text)
    if span is None:
        print(f"bot-instructions: region-input={path}", file=sys.stderr)
        print(render.not_located(text), file=sys.stderr)
        return 2
    print(f"region bounds\t{span[0]}\t{span[1]}")
    return 0


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
    p = parser()
    p.given = tuple(sys.argv[1:] if argv is None else argv)
    args = p.parse_args(argv)
    if args.verb == "region-bounds":
        if args.input is None:
            p.error("region-bounds requires --input")
        return _region_bounds(args.input)
    if args.input is not None:
        p.error("--input belongs to region-bounds")
    if args.staged and args.verb != "check":
        print("bot-instructions: usage=--staged", file=sys.stderr)
        print("--staged is a check mode; render and adopt write the working tree",
              file=sys.stderr)
        return 2
    if args.dry_run and args.verb != "render":
        # `adopt` is the one-time verb that writes, so a flag it accepted and
        # ignored would take the files over on a run meant to preview.
        print("bot-instructions: usage=--dry-run", file=sys.stderr)
        print(f"--dry-run is a render mode; {args.verb} does not write a set to preview",
              file=sys.stderr)
        return 2
    if args.verb == "retire":
        print("automatic bot-instructions rendering retired; generated files are unchanged")
        return 0
    # The two roots an operator names are resolved through their symlinks
    # once, here. Containment is about not escaping the resolved root, never
    # about how the operator spelled it, and in a kendex-installed repo the
    # documented `--spec` value is `.agents/skills/bot-instructions`, which is
    # a symlink to the package: the no-follow walk below that root would
    # otherwise refuse the root itself.
    repo = os.path.realpath(args.repo)
    package_root = running_copy()
    spec_root = os.path.realpath(args.spec) if args.spec else package_root
    try:
        work = tree.open_tree(repo, args.staged)
        spec_tree, spec_paths = _spec_source(repo, spec_root, work, args.staged)
        launcher = os.path.join(package_root, "scripts", "bot-instructions")
        ctx = run.Context(repo, work, spec_tree, spec_paths,
                          "render" if args.verb == "render" else "check",
                          spec_names=SPEC_FILES, launcher=launcher)
        if args.verb == "render":
            lines = verbs.render_verb(ctx, repo, dry_run=args.dry_run)
        elif args.verb == "check":
            lines = verbs.check_verb(ctx)
        else:
            lines = verbs.adopt_verb(ctx, repo)
    except ValidationFailed as exc:
        for line in exc.report:
            print(line)
        # stdout block-buffers when it is not a terminal and flushes at exit,
        # while stderr does not, so through a pipe the record would print
        # first and the report last. Every automated reader of this verb
        # captures with `2>&1`, and `errors.ValidationFailed` states the
        # order the other way round.
        sys.stdout.flush()
        print(f"bot-instructions: findings={len(exc.findings)}", file=sys.stderr)
        for finding in exc.findings:
            print(finding, file=sys.stderr)
        return 1
    except BotInstructionsError as exc:
        # Could not complete, which is 2 in the exit convention the
        # commit-guards pre-commit lane reads: 0 clean, 1 findings, 2 the
        # check could not answer. Everything a validator can attribute to the
        # repo's own inputs is already a `ValidationFailed` by the time it
        # reaches here (`run._as_finding`), so what arrives as a bare error is
        # a source git could not answer for, an unusable spec copy, or a
        # write that failed — none of them a violation in the tree.
        # A failure reading the spec copy is about that copy, whichever
        # family it arrives as: a spec file that will not decode raises a
        # render failure, and naming the repository there would send a caller
        # to the wrong tree. `subject` is set where the spec source is read.
        subject = getattr(exc, "subject", None)
        if subject is None:
            from_spec = isinstance(exc, SpecError) or getattr(exc, "from_spec", False)
            subject = spec_root if from_spec else repo
        print(f"bot-instructions: {exc.key}={subject}", file=sys.stderr)
        print(str(exc), file=sys.stderr)
        return 2
    except Exception:  # a crash is not a finding either
        print(f"bot-instructions: crashed={repo}", file=sys.stderr)
        traceback.print_exc()
        return 2
    for line in lines:
        print(line)
    return 0
