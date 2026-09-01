"""One run: what every validator reads, and which ones the verb runs.

`validators.md` § Where these run is the split. Byte validators judge one
render and read the scratch tree on both verbs. Repo-state validators judge
the repository, so a scratch tree is the one place they cannot fail.

`drift` is the one check with no question to answer at render time — a render
exists to change the bytes it compares — and the run says it was skipped
rather than counting it as passed.
"""

import contextlib

from .constants import CODERABBIT_SCHEMA_PATH, TOML_PATH
from .errors import (Finding, InputError, ManifestError, SourceUnavailable,
                     ValidationFailed)
from . import config as config_mod
from . import model as model_mod
from . import render as render_mod
from . import spec as spec_mod
from . import validators_bytes as vb
from . import validators_repo as vr

BYTE_VALIDATORS = (
    vb.doctrine_routing,
    vb.coderabbit_schema,
    vb.copilot_budget,
    vb.qodo_parity,
    vb.qodo_best_practices,
)
REPO_VALIDATORS = (vr.agents_section, vr.orphan, vr.drift)


@contextlib.contextmanager
def _as_finding(validator, path, other=None, other_path=None):
    """Attribute an input failure to the validator whose clause it is."""
    try:
        yield
    except SourceUnavailable:
        # A source that could not answer is nobody's clause. Attributing it to
        # the validator that happened to need it first reports a defect in the
        # repo's TOML for a git that would not run, and sends the reader to
        # the wrong file.
        raise
    except ManifestError as exc:
        # `other_path` passes THROUGH, `None` included. Every manifest message
        # names its own file or row, so a trailing `[bot-instructions.toml]`
        # would send the reader to a file that is correct.
        raise ValidationFailed([Finding(other or validator, str(exc), other_path)]) from exc
    except InputError as exc:
        raise ValidationFailed([Finding(validator, str(exc), path)]) from exc


class Context:
    def __init__(self, root, tree, spec_tree, spec_paths, verb, spec_names):
        # `spec_paths` is how the spec copy is READ; `spec_names` is how the
        # marker records it. They differ under `--staged`, where the spec copy
        # is read from the index at its repo-relative path, and wherever the
        # spec copy sits outside the repo: an absolute checkout path in a
        # rendered file would make the render depend on where CI put the
        # trusted checkout. Both are required, so no caller can leave the
        # marker recording whatever path this run happened to read.
        spec_names = list(spec_names)
        self.root = root
        self.tree = tree
        self.verb = verb
        self.skipped = []
        toml_text = tree.read(TOML_PATH)
        if toml_text is None:
            raise InputError(f"{TOML_PATH}: absent at the repo root")
        with _as_finding("toml-schema", TOML_PATH):
            self.config = config_mod.parse(toml_text, TOML_PATH)
        self.doctrine = spec_mod.load(spec_tree, *spec_paths)
        self.frozen_ids = spec_mod.frozen_ids()
        # An unknown `[doctrine.*]` block id is a `toml-schema` clause; a
        # manifest that declares no install is an `exclusion-consistency` one.
        # Both are raised where the value is first needed, and both are the
        # validator's finding rather than an unattributed failure — a control
        # asserts on the validator's own identity.
        with _as_finding("toml-schema", TOML_PATH, "exclusion-consistency"):
            self.model = model_mod.build(tree, self.config, self.doctrine, spec_names)
        self.schema = None
        if self.config.bots["coderabbit"]:
            with _as_finding("coderabbit-schema", CODERABBIT_SCHEMA_PATH):
                self.schema = render_mod.load_schema(tree)
        with _as_finding("toml-schema", TOML_PATH):
            self.build = render_mod.build(self.model, self.schema)
        self._tracked = None

    def read(self, rel):
        return self.tree.read(rel)

    def walk(self, prefix):
        return self.tree.walk(prefix)

    def tracked_paths(self):
        if self._tracked is None:
            self._tracked = self.tree.tracked()
        return self._tracked


def validate(ctx):
    """Every finding, from every validator the verb runs."""
    findings = []
    for check in BYTE_VALIDATORS:
        check(ctx, findings)
    vr.exclusion_consistency(ctx, findings)
    for check in REPO_VALIDATORS:
        if check is vr.drift and ctx.verb == "render":
            ctx.skipped.append(
                "drift: skipped on render. A render exists to change the bytes it "
                "compares, so at render time it would red on its own purpose."
            )
            continue
        check(ctx, findings)
    return findings


def require_clean(ctx):
    findings = validate(ctx)
    if findings:
        raise ValidationFailed(findings)
