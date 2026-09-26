"""Everything a render reads, assembled once.

SKILL.md § The render inputs is the one statement of the input set: the marker
names them, `check --staged` reads each from the index, and the policy set
contains them. `RenderModel.inputs` is this implementation's single copy of
that list.
"""

from .constants import CODERABBIT_SCHEMA_PATH
from .errors import InputError, ManifestError, SpecError
from . import config as config_mod, manifest, marker as marker_mod, spec


class RenderModel:
    def __init__(self, config, doctrine, exclusions, inputs, surfaces):
        # Every path here is interpolated into the marker comment, so every
        # path here meets the class that cannot close one. This is the
        # backstop for the paths that are this package's own constants;
        # `build` checks the manifest-derived ones against their own source,
        # so their refusal names the file that produced them.
        for path in inputs:
            spec.check_marker_path(path)
        self.config = config
        self.doctrine = doctrine
        self.exclusions = exclusions      # ordered [{glob, reason, derived}]
        self.inputs = inputs              # every path this render read
        # The repo's `[[bot-instructions.surface]]` set, then the spec copy's
        # defaults. Every route that renders surfaces reads this list.
        self.surfaces = surfaces
        self._blocks, self._repo_authored = _assemble(config, doctrine)

    @property
    def repo_name(self):
        return self.config.repo["name"]

    @property
    def summary(self):
        return self.config.repo["summary"]

    @property
    def code_review_path(self):
        """Where this repo's complete review doctrine is written.

        `[bot-instructions.repo] code_review_path`, whose default is the one
        `constants` holds. Read by the render that writes the file, by the
        `AGENTS.md` directive, by the Copilot pointer and by CodeRabbit's
        `code_guidelines.filePatterns`.
        """
        return self.config.repo["code_review_path"]

    def blocks_for(self, column):
        """The blocks that column carries, in the routing table's order."""
        return [(bid, self._blocks[bid]) for bid in self.doctrine.routing[column]]

    def block(self, bid):
        return self._blocks[bid]

    def repo_authored(self, bid):
        """Whether a repository append or replacement supplies any block text."""
        return bid in self._repo_authored

    @property
    def exclusion_globs(self):
        return [e["glob"] for e in self.exclusions]

    def derived(self):
        return [e for e in self.exclusions if e["derived"]]

    def marker(self, style):
        """The marker comment, in `style`: 'html' or 'hash'.

        `marker.comment` is the form, and `marker.owns` tests for that same
        function's output, so the string this render writes and the string
        ownership is tested for are one.
        """
        return marker_mod.comment(style, self.doctrine.version, self.inputs)


def _assemble(config, doctrine):
    """Return block text and repository override kinds by block ID.

    The second half is the origin `repo_authored` answers from, recorded here
    because here is the only place both inputs are still distinguishable.
    """
    known = set(doctrine.blocks)
    for kind, table in (("append", config.doctrine_append), ("replace", config.doctrine_replace)):
        for bid in table:
            if bid not in known:
                raise InputError(
                    f"{config.where} [bot-instructions.doctrine.{kind}]: {bid!r} is not a doctrine block id. "
                    f"Known ids: {', '.join(sorted(known))}"
                )
    tracker = config.repo["tracker"]
    out = {}
    from_repo = {}
    for bid, text in doctrine.blocks.items():
        if bid in config.doctrine_replace:
            text = config.doctrine_replace[bid].strip("\n")
            from_repo[bid] = "replace"
        elif bid in config.doctrine_append:
            text = text + "\n\n" + config.doctrine_append[bid].strip("\n")
            from_repo[bid] = "append"
        if bid == "reply-contract":
            text = text.replace("<issue>", f"<{tracker}-n>" if tracker else "<issue>")
        out[bid] = text
    return out, from_repo


def build(tree, config, doctrine, spec_paths, resolved):
    """Resolve the exclusion set and the input list for one render."""
    inputs = list(resolved.paths)
    if config.exclusions["derive_render"]:
        # The record the skill half of the derivation reads, named where the
        # manifests are: a marker that omits it says the render read less
        # than it did.
        inputs.append(manifest.INVENTORY)
    inputs += list(spec_paths)
    for path in resolved.paths:
        try:
            spec.check_marker_path(path)
        except InputError as exc:
            raise ManifestError(str(exc)) from exc
    exclusions = []
    if config.bots["coderabbit"]:
        inputs.append(CODERABBIT_SCHEMA_PATH)
    if config.exclusions["derive_render"]:
        exclusions.extend(manifest.derive(tree, resolved))
    for entry in config.exclusions["path"]:
        exclusions.append({"glob": entry["glob"], "reason": entry["reason"], "derived": False})
    if config.bots["codex"]:
        inputs.append("AGENTS.md")
    _check_duplicates(exclusions, config.where)
    return RenderModel(config, doctrine, exclusions, inputs,
                       config.surfaces + _default_surfaces(config, doctrine))


def _default_surfaces(config, doctrine):
    """The spec copy's surfaces, judged as the manifest's own are.

    A refusal is the spec copy's defect, not the repo's, so it leaves as a
    `SpecError`. A repo surface taking a default's `name` is the repo's: the
    two would render to one file, and only the later write would survive.
    """
    try:
        defaults = config_mod.surfaces(doctrine.surfaces, "SKILL.md § Default surfaces")
    except InputError as exc:
        raise SpecError(str(exc)) from exc
    taken = {s["name"] for s in config.surfaces}
    for surface in defaults:
        if surface["name"] in taken:
            raise InputError(
                f"{config.where} [[bot-instructions.surface]] name: {surface['name']!r} is a "
                "surface this package renders in every repo (SKILL.md § Default surfaces). "
                "Drop the repo's entry"
            )
    return defaults


def _check_duplicates(exclusions, where):
    """One glob, one entry, in every destination.

    A `[[bot-instructions.exclusions.path]]` entry naming a tree `derive_render` already
    derives is the common case, and it is still a duplicate: it renders the
    same pattern twice with two different reasons beside it, and the second
    reason is the one a reader believes.
    """
    seen = set()
    for entry in exclusions:
        if entry["glob"] in seen:
            raise InputError(
                f"{where}: exclusion {entry['glob']!r} is declared twice. If "
                "`[bot-instructions.exclusions] derive_render` already derives that tree, drop the "
                "`[[bot-instructions.exclusions.path]]` entry rather than restating it"
            )
        seen.add(entry["glob"])


def exclude_sentence(surface):
    """The closing paragraph a surface's `exclude_globs` renders as.

    Real subtraction only on Macroscope, which has an `exclude` frontmatter
    key. Copilot's frontmatter has no exclude key and CodeRabbit's
    `path_instructions` entry has no exclude field, so on both the subtraction
    is prose: those bots load the instructions for the excluded files and are
    asked to disregard them.

    A blank line before it, never a space: `instructions` ending in a fenced
    code block end on the closing fence, which closes nothing once there is
    text after it on the line, and the sentence and everything after it then
    render as literal code.
    """
    excl = surface.get("exclude_globs")
    if not excl:
        return ""
    return "\n\nThese rules do not cover " + ", ".join(excl) + "."
