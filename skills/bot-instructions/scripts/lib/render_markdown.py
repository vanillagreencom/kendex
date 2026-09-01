"""The markdown outputs.

`schemas/renders.md` states each body. Escaping is markdown passed through:
doctrine text does not come through `bot-instructions.toml`, so its refusals
run in `spec.parse_doctrine` before any of this.
"""

from .model import exclude_sentence

AGENTS_HEADING = "## Code Review Rules"

AUDIENCE = (
    "For automated reviewers on this repository. A working agent reads the rest of "
    "this file; these rules govern review comments only."
)

POINTER = (
    "Author replies and the rest of the review contract are in `AGENTS.md` "
    "§ Code Review Rules, which Copilot code review reads on GitHub.com."
)

PATH_RULES = (
    "Per-path review rules live in `.github/instructions/`, one file per path set."
)


def paragraphs(text):
    out, cur = [], []
    for line in text.splitlines():
        if line.strip() == "":
            if cur:
                out.append(" ".join(cur))
                cur = []
        else:
            cur.append(line.strip())
    if cur:
        out.append(" ".join(cur))
    return out


def summary_block(model):
    """`[repo] summary` as the repo wrote it.

    `renders.md` § Common rules: repo text is never reflowed, and
    `tone_instructions` is the only line-break exception. `paragraphs` is for
    doctrine, which this package hard-wraps in its own spec copy for that
    file's sake. This is the one form of the summary, so no two surfaces can
    carry it differently.
    """
    return model.summary.strip("\n")


def block_paragraphs(model, bid, text):
    """A block's paragraphs, for an output that keeps paragraphs apart.

    Package-authored doctrine is joined: this package hard-wraps its own prose
    in the spec copy, and those breaks belong to that file rather than to the
    meaning. A block a repo overrode keeps every line break it was written
    with, per `renders.md` § Common rules — a fenced example needs its own.
    `model.repo_authored` is the distinction.
    """
    if model.repo_authored(bid):
        return [text.strip("\n")]
    return paragraphs(text)


def as_bullet(text):
    """One block, exactly one bullet, no blank line inside.

    A repo guard that pins the reply contract reads it as a single bullet, and
    a blank line ends that read. So this joins whatever the block's origin:
    the owned region is the second place a target forbids line breaks, and
    § Common rules names it beside `tone_instructions`.
    """
    return "- " + " ".join(paragraphs(text))


def agents_region_body(model):
    """The body the write phase splices under the `## Code Review Rules` line."""
    lines = [model.marker("html"), "", AUDIENCE, ""]
    excl = model.exclusion_globs
    for bid, text in model.blocks_for("AGENTS.md"):
        bullet = as_bullet(text)
        if bid == "render-out-of-scope" and excl:
            bullet = bullet + " Those paths here: " + ", ".join(excl) + "."
        lines.append(bullet)
    lines.append("")
    return "\n".join(lines)


def copilot_instructions(model):
    out = [model.marker("html"), ""]
    out.append(f"# {model.repo_name}")
    out.append("")
    out.append(summary_block(model))
    out.append("")
    out.append("# Code review calibration")
    out.append("")
    for bid, text in model.blocks_for("copilot-instructions"):
        out.append(f"## {bid}")
        out.append("")
        for para in block_paragraphs(model, bid, text):
            out.append(para)
            out.append("")
    out.append("## Reply contract")
    out.append("")
    out.append(POINTER)
    out.append("")
    if model.config.surfaces:
        out.append("## Path rules")
        out.append("")
        out.append(PATH_RULES)
        out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def instructions_file(model, surface):
    """`.github/instructions/<name>.instructions.md`.

    `applyTo` is a single non-empty string holding a comma-separated glob
    list, not a YAML array. The glob dialect refuses a comma, so the join is
    unambiguous, and it refuses `"`, so no escaping is needed.
    """
    apply_to = ",".join(surface["globs"])
    front = ["---", f'applyTo: "{apply_to}"']
    if surface["reviewer_only"]:
        # The value names the agent the file is hidden FROM, so `cloud-agent`
        # keeps it from the working agent and leaves code review reading it.
        front.append('excludeAgent: "cloud-agent"')
    front.append("---")
    body = surface["instructions"].rstrip("\n") + exclude_sentence(surface)
    return "\n".join(front + ["", model.marker("html"), "", body, ""])


def review_md(model):
    out = [model.marker("html"), ""]
    for bid, text in model.blocks_for("REVIEW.md"):
        out.append(f"## {bid}")
        out.append("")
        for para in block_paragraphs(model, bid, text):
            out.append(para)
            out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def best_practices(model):
    """Surface text's only route to Qodo. No doctrine: `.pr_agent.toml` has it."""
    out = [model.marker("html"), ""]
    for surface in model.config.surfaces:
        out.append(f"## {surface['name']}")
        out.append("")
        out.append("Applies to " + ", ".join(surface["globs"]) + ".")
        out.append("")
        out.append(surface["instructions"].strip("\n") + exclude_sentence(surface))
        out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def macroscope_ignore(model):
    """One glob per line, `#` comments, blank lines ignored.

    That is the grammar Macroscope documents for this file, and it is not
    markdown's: an HTML comment here is a pattern, not a comment, so the
    marker and every reason take the `#` form.
    """
    out = [model.marker("hash"), ""]
    for entry in model.exclusions:
        out.append(f"# {entry['reason']}")
        out.append(entry["glob"])
    return "\n".join(out).rstrip("\n") + "\n"


def macroscope_doctrine(model):
    """No frontmatter, so it applies repo-wide. Carries every block."""
    out = [model.marker("html"), ""]
    for bid, text in model.blocks_for("macroscope doctrine.md"):
        out.append(f"## {bid}")
        out.append("")
        for para in block_paragraphs(model, bid, text):
            out.append(para)
            out.append("")
    out.append("## about this repository")
    out.append("")
    out.append(summary_block(model))
    out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def macroscope_surface(model, surface):
    """`include` from `globs`, `exclude` from `exclude_globs`, both YAML arrays.

    Macroscope evaluates `exclude` after `include`, which matches the TOML's
    meaning directly, so this is the one surface where the subtraction needs
    no restatement in prose.
    """
    front = ["---", "include:"]
    for g in surface["globs"]:
        front.append(f'  - "{g}"')
    if surface["exclude_globs"]:
        front.append("exclude:")
        for g in surface["exclude_globs"]:
            front.append(f'  - "{g}"')
    front.append("---")
    body = surface["instructions"].strip("\n")
    return "\n".join(front + ["", model.marker("html"), "", body, ""])
