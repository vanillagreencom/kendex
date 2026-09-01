"""Everything a render reads, assembled once.

SKILL.md § The render inputs is the one statement of the input set: the marker
names them, `check --staged` reads each from the index, every one is under the
open rule, and the policy set contains them. `RenderModel.inputs` is this
implementation's single copy of that list, and the marker, the staged read and
`drift`'s controls all take it from here rather than each naming its own set.
"""

from .constants import (
    CODERABBIT_SCHEMA_PATH,
    MARKER_CLOSE,
    MARKER_TOKEN,
    TOML_PATH,
)
from .errors import InputError, ManifestError
from . import manifest, spec


class RenderModel:
    def __init__(self, config, doctrine, exclusions, inputs):
        # Every path here is interpolated into the marker comment, so every
        # path here meets the class that cannot close one, which is what
        # keeps `spec.py`'s claim and `renders.md` § Common rules true as the
        # list grows repo-derived members. This is the backstop for the paths
        # that are this package's own constants: `build` has already checked
        # the manifest-derived ones against their own source, because a
        # refusal naming the wrong file is the failure `errors.py` calls out
        # by name.
        for path in inputs:
            spec.check_marker_path(path)
        self.config = config
        self.doctrine = doctrine
        self.exclusions = exclusions      # ordered [{glob, reason, derived}]
        self.inputs = inputs              # every path this render read
        self._blocks = _assemble(config, doctrine)

    @property
    def repo_name(self):
        return self.config.repo["name"]

    @property
    def summary(self):
        return self.config.repo["summary"]

    def blocks_for(self, column):
        """The blocks that column carries, in the routing table's order."""
        return [(bid, self._blocks[bid]) for bid in self.doctrine.routing[column]]

    def block(self, bid):
        return self._blocks[bid]

    @property
    def exclusion_globs(self):
        return [e["glob"] for e in self.exclusions]

    def derived(self):
        return [e for e in self.exclusions if e["derived"]]

    def marker(self, style):
        """The marker comment, in `style`: 'html' or 'hash'."""
        paths = ", ".join(self.inputs)
        head = f"{MARKER_TOKEN} {self.doctrine.version} from {paths}."
        if style == "html":
            # One comment on ONE line. `.macroscope/ignore.md` reads every
            # non-blank line as a pattern unless the whole line is a comment,
            # so a marker wrapped across two lines would put its second line
            # into that file as a pattern.
            return f"<!-- {head} {MARKER_CLOSE} -->"
        return f"# {head}\n# {MARKER_CLOSE}"


def _assemble(config, doctrine):
    """Block text, with `[doctrine.replace]`, `[doctrine.append]`, `<issue>`."""
    known = set(doctrine.blocks)
    for kind, table in (("append", config.doctrine_append), ("replace", config.doctrine_replace)):
        for bid in table:
            if bid not in known:
                raise InputError(
                    f"{TOML_PATH} [doctrine.{kind}]: {bid!r} is not a doctrine block id. "
                    f"Known ids: {', '.join(sorted(known))}"
                )
    tracker = config.repo["tracker"]
    out = {}
    for bid, text in doctrine.blocks.items():
        if bid in config.doctrine_replace:
            text = config.doctrine_replace[bid].strip("\n")
        elif bid in config.doctrine_append:
            text = text + "\n\n" + config.doctrine_append[bid].strip("\n")
        if bid == "reply-contract":
            text = text.replace("<issue>", f"<{tracker}-n>" if tracker else "<issue>")
        out[bid] = text
    return out


def build(tree, config, doctrine, spec_paths):
    """Resolve the exclusion set and the input list for one render."""
    inputs = [TOML_PATH] + list(spec_paths)
    exclusions = []
    if config.bots["coderabbit"]:
        inputs.append(CODERABBIT_SCHEMA_PATH)
    if config.exclusions["derive_render"]:
        resolved, read = manifest.resolve(tree)
        exclusions.extend(manifest.derive(tree, resolved))
        # The one member of the input list a repo decides, so the one whose
        # marker-path refusal is a manifest finding. Checked here, where the
        # source is still known: the sweep in `RenderModel.__init__` sees a
        # flat list and would report a manifest-derived path as a
        # `bot-instructions.toml` defect, sending the reader to a file holding
        # nothing wrong.
        for path in read:
            try:
                spec.check_marker_path(path)
            except InputError as exc:
                raise ManifestError(str(exc)) from exc
        inputs.extend(read)
    for entry in config.exclusions["path"]:
        exclusions.append({"glob": entry["glob"], "reason": entry["reason"], "derived": False})
    if config.bots["codex"]:
        inputs.append("AGENTS.md")
    _check_duplicates(exclusions)
    return RenderModel(config, doctrine, exclusions, inputs)


def _check_duplicates(exclusions):
    """One glob, one entry, in every destination.

    A `[[exclusions.path]]` entry naming a tree `derive_render` already
    derives is the common case, and it is still a duplicate: it renders the
    same pattern twice with two different reasons beside it, and the second
    reason is the one a reader believes.
    """
    seen = set()
    for entry in exclusions:
        if entry["glob"] in seen:
            raise InputError(
                f"{TOML_PATH}: exclusion {entry['glob']!r} is declared twice. If "
                "`[exclusions] derive_render` already derives that tree, drop the "
                "`[[exclusions.path]]` entry rather than restating it"
            )
        seen.add(entry["glob"])


def exclude_sentence(surface):
    """The closing sentence a surface's `exclude_globs` renders as.

    Real subtraction only on Macroscope, which has an `exclude` frontmatter
    key. Copilot's frontmatter has no exclude key and CodeRabbit's
    `path_instructions` entry has no exclude field, so on both the subtraction
    is prose: those bots load the instructions for the excluded files and are
    asked to disregard them.
    """
    excl = surface.get("exclude_globs")
    if not excl:
        return ""
    return " These rules do not cover " + ", ".join(excl) + "."
