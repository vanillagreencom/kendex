"""One run: what every validator reads, and which ones the verb runs.

`validators.md` § Where these run is the split. Byte validators judge one
render and read the scratch tree on both verbs. Repo-state validators judge
the repository, so a scratch tree is the one place they cannot fail.

With a `[bot-instructions]` table, `drift` and the file half of `orphan` are
the checks with no question to answer at render time — a render exists to
change the bytes `drift` compares, and it removes the files `orphan` names —
and the run says each was skipped rather than counting it as passed. With no
table no validator runs; `validators.md` § `orphan` says what the run reports.
"""

import contextlib
import os

from .constants import CODERABBIT_SCHEMA_PATH
from . import manifest
from .errors import (Finding, InputError, ManifestError, SourceUnavailable, SpecError,
                     Unconfigured, ValidationFailed)
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
REPO_VALIDATORS = (vr.agents_section, vr.orphan_file, vr.orphan_region, vr.drift)
# What `render` does instead of each validator it skips, said in its output.
# Holds with a `[bot-instructions]` table only: with none, `Context` stops
# before any validator runs.
RENDER_SKIPS = {
    vr.drift: "drift: skipped on render. A render exists to change the bytes it "
              "compares, so at render time it would red on its own purpose.",
    vr.orphan_file: "orphan: marked files skipped on render. A render removes each "
                    "one after its writes.",
}


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
        # Manifest errors already name their source. A config path suffix
        # would attribute a derivation error to the bot table.
        raise ValidationFailed([Finding(other or validator, str(exc), other_path)]) from exc
    except InputError as exc:
        raise ValidationFailed([Finding(validator, str(exc), path)]) from exc


class Context:
    def __init__(self, root, tree, spec_tree, spec_paths, verb, spec_names, launcher,
                 output_mode="full", installed_spec=None):
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
        self.launcher = launcher
        self.skipped = []
        with _as_finding("toml-schema", None):
            resolved = manifest.resolve(tree)
        config_path = resolved.chosen
        if "bot-instructions" not in resolved.data:
            # `validators.md` § `orphan`, the no-table case.
            self.build = render_mod.Build(None, {}, {}, None, output_mode)
            stranded = vr.unconfigured_orphans(tree, config_path, self.build.remote)
            if stranded:
                raise ValidationFailed(stranded)
            # The orphan scan proves this empty result. Keep it as the
            # configuration state so render and every check mode agree;
            # adopt still needs a configured set to take ownership of.
            self.config = Unconfigured(config_path)
            return
        with _as_finding("toml-schema", config_path):
            self.config = config_mod.parse(
                resolved.data.get("bot-instructions"), f"{config_path} [bot-instructions]"
            )
        self.doctrine = spec_mod.load(spec_tree, *spec_paths)
        local_review_path = None
        if output_mode == "local":
            if installed_spec is None:
                external = os.path.join(spec_tree.root, spec_paths[0])
                error = SpecError(
                    f"{external}: local output needs an installation inside the checkout. "
                    "Use --output full, or install the package inside the checkout"
                )
                error.subject = external
                raise error
            local_review_path = os.path.relpath(
                os.path.join(installed_spec, "SKILL.md"), root
            ).replace(os.sep, "/") + "#doctrine"
        self.frozen_ids = spec_mod.frozen_ids()
        # An unknown `[bot-instructions.doctrine.*]` block id is a `toml-schema` clause; a
        # manifest that declares no install is an `exclusion-consistency` one.
        # Both are raised where the value is first needed, and both are the
        # validator's finding rather than an unattributed failure — a control
        # asserts on the validator's own identity.
        with _as_finding("toml-schema", config_path, "exclusion-consistency"):
            self.model = model_mod.build(tree, self.config, self.doctrine, spec_names, resolved)
        def schema_loader():
            with _as_finding("coderabbit-schema", CODERABBIT_SCHEMA_PATH):
                return render_mod.load_schema(tree)
        with _as_finding("toml-schema", config_path):
            self.build = render_mod.build(self.model, output_mode=output_mode,
                                          schema_loader=schema_loader,
                                          local_review_path=local_review_path)
        self.schema = self.build.schema
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
    if ctx.build.remote:
        for check in BYTE_VALIDATORS:
            check(ctx, findings)
        vr.exclusion_consistency(ctx, findings)
    for check in REPO_VALIDATORS:
        if ctx.verb == "render" and check in RENDER_SKIPS:
            ctx.skipped.append(RENDER_SKIPS[check])
            continue
        check(ctx, findings)
    return findings


def require_clean(ctx):
    findings = validate(ctx)
    if findings:
        raise ValidationFailed(findings)
