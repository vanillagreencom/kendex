"""`.coderabbit.yaml`: full state, driven by the vendored schema.

An unset key resolves down a precedence ladder this package does not control,
so the render writes full state including keys that match their schema
default. **`renders.md` § `.coderabbit.yaml` § Keys states which properties
that is**, and `in_full_state` below is the one predicate that answers it, so
the render and `coderabbit-schema`'s completeness clause cannot make a state
no config satisfies.

Walking the schema rather than transcribing a key list is what makes that true
at every depth: a nested option a vendor adds arrives at its own default and
shows in the diff. `overrides` is where this package has an opinion;
everything else is the vendor's default, written explicitly.
"""

from .constants import (
    CODERABBIT_SCHEMA_LINE,
    CODERABBIT_SCHEMA_PATH,
    CODERABBIT_TOP_LEVEL,
    DEFAULT_TONE,
)
from .model import exclude_sentence
from . import yamlemit


def tone(model):
    """`[tone] coderabbit` with newlines collapsed, emitted as a folded scalar.

    The 250-character cap is the vendored schema's own `maxLength`, so
    `coderabbit-schema` is its single enforcer and this carries no second copy
    of the number.
    """
    raw = model.config.tone["coderabbit"] or DEFAULT_TONE
    return " ".join(raw.split())


def path_filters(model):
    """Exclusion-only. A single entry without `!` turns this into an allowlist."""
    return ["!" + e["glob"] for e in model.exclusions]


def path_instructions(model):
    out = []
    for surface in model.config.surfaces:
        gs = surface["globs"]
        # Joined as a brace alternation, which minimatch understands and which
        # is safe here because path_instructions never reaches sparse-checkout.
        path = gs[0] if len(gs) == 1 else "{" + ",".join(gs) + "}"
        out.append({
            "path": path,
            "instructions": surface["instructions"].strip("\n") + exclude_sentence(surface),
        })
    if model.exclusions:
        # The path filters already remove those trees; this is what stops a
        # finding arriving through a file that references them.
        #
        # One line for this package's own prose, whose breaks are the spec
        # copy's wrapping. A block a repo overrode keeps its own, like every
        # other destination, and then the paths need a paragraph of their own
        # so an override ending in a fence still closes it.
        bid = "render-out-of-scope"
        text = model.block(bid)
        joined = not model.repo_authored(bid)
        if joined:
            text = text.replace("\n", " ")
        out.append({
            "path": "**",
            "instructions": text + (" " if joined else "\n\n")
            + "Those paths here: " + ", ".join(model.exclusion_globs) + ".",
        })
    return out


def overrides(model):
    """Every value this package chooses, by dotted schema path."""
    cadence = model.config.cadence
    o = {
        "tone_instructions": tone(model),
        "early_access": False,
        "inheritance": False,
        "reviews.profile": "chill",
        "reviews.request_changes_workflow": True,
        "reviews.review_status": True,
        "reviews.commit_status": True,
        "reviews.collapse_walkthrough": True,
        "reviews.path_filters": path_filters(model),
        "reviews.path_instructions": path_instructions(model),
        "reviews.auto_review.auto_incremental_review": cadence["coderabbit_incremental"],
        "reviews.auto_review.drafts": cadence["coderabbit_drafts"],
        # Fleet experience, not documented behavior: naming the default branch
        # has been observed to skip pull requests targeting it, and the
        # wildcard also covers stacked pull requests.
        "reviews.auto_review.base_branches": [".*"],
        "knowledge_base.opt_out": False,
        "knowledge_base.code_guidelines.filePatterns": ["AGENTS.md"],
        "knowledge_base.learnings.scope": "local",
        "knowledge_base.issues.scope": "local",
        "knowledge_base.pull_requests.scope": "local",
    }
    # Every summary, decoration, labelling, reviewer-suggestion and fortune
    # key false: this package renders a findings-only posture.
    for key in (
        "high_level_summary", "high_level_summary_in_walkthrough", "review_details",
        "review_progress", "fail_commit_status", "changed_files_summary",
        "sequence_diagrams", "estimate_code_review_effort", "assess_linked_issues",
        "related_issues", "related_prs", "suggested_labels", "auto_apply_labels",
        "suggested_reviewers", "auto_assign_reviewers", "in_progress_fortune", "poem",
    ):
        o[f"reviews.{key}"] = False
    # This package never lets a bot push code.
    for key in ("docstrings", "unit_tests", "simplify", "autofix", "fix_ci",
                "resolve_merge_conflict"):
        o[f"reviews.finishing_touches.{key}.enabled"] = False
    for key in ("docstrings", "title", "description", "issue_assessment"):
        o[f"reviews.pre_merge_checks.{key}.mode"] = "off"
    # This package configures review, not issue triage.
    o["issue_enrichment.auto_enrich.enabled"] = False
    o["issue_enrichment.planning.enabled"] = False
    o["issue_enrichment.planning.auto_planning.enabled"] = False
    o["issue_enrichment.labeling.auto_apply_labels"] = False
    return o


def in_full_state(sub, chosen, here):
    """Does full state carry this property? The one predicate, read twice.

    `coderabbit-schema`'s completeness clause asks the same question of the
    rendered document, and two predicates that disagree make a state no config
    can satisfy: an object whose subtree defines no defaults would be omitted
    by the render and required by the validator, blocking every run.
    """
    if here in chosen:
        return True
    if sub.get("type") == "object" and sub.get("properties"):
        return "default" in sub or any(
            in_full_state(child, chosen, f"{here}.{name}")
            for name, child in (sub.get("properties") or {}).items()
        )
    return "default" in sub


def full_state(schema, chosen, path=""):
    """The full-state set of `renders.md` § `.coderabbit.yaml` § Keys."""
    props = schema.get("properties") or {}
    out = {}
    for key, sub in props.items():
        here = f"{path}.{key}" if path else key
        if not in_full_state(sub, chosen, here):
            continue
        if here in chosen:
            out[key] = chosen[here]
        elif sub.get("type") == "object" and sub.get("properties"):
            # MERGED, not chosen between. An object's own default may carry
            # keys its `properties` do not describe, and the walk cannot see
            # them, so taking the recursion alone drops those sub-keys and
            # they resume resolving down the ladder. The walked values win
            # where both name a key.
            out[key] = _merged(sub.get("default"), full_state(sub, chosen, here))
        else:
            out[key] = sub["default"]
    return out


def _merged(default, nested):
    """An object's own default under the values the walk produced.

    A `default` that is not a mapping cannot merge, and `null` is the case
    that matters: emitting it would reach `yamlemit` as None, which has no
    YAML form and raises with no validator named. An object property whose
    default says "nothing here" is the empty mapping this walk already
    produces for it.
    """
    if not isinstance(default, dict):
        return nested
    return {**default, **nested}


def unresolved(schema, chosen):
    """Every override key naming no property the vendored schema defines.

    `full_state` walks the schema and consults `chosen` by dotted path, so an
    override for a property the schema does not define is not applied — it is
    dropped, and the key resolves to the vendor default with nothing said.
    Renaming a property is exactly what a vendored-schema refresh does, and
    refreshing that copy is a documented checklist step.
    """
    defined = set()

    def walk(node, path):
        for key, sub in (node.get("properties") or {}).items():
            here = f"{path}.{key}" if path else key
            defined.add(here)
            walk(sub, here)

    walk(schema, "")
    return sorted(k for k in chosen if k not in defined)


def unresolved_message(missing):
    """What `coderabbit-schema` says about the keys `unresolved` returned.

    A finding rather than a raise from here: a `RenderError` out of the render
    escapes `run._as_finding` and reaches the operator naming no validator.
    `render_verb` validates before it writes, so it is no less fail-closed.
    """
    return (
        f"{', '.join(repr(k) for k in missing)} "
        f"{'is a value' if len(missing) == 1 else 'are values'} this package chooses "
        f"and the vendored {CODERABBIT_SCHEMA_PATH} defines no such property. "
        "A dropped override resolves to the vendor default with nothing said, "
        "and a refreshed schema that renames a property is how that happens. "
        "Refresh this package's overrides against the vendored copy"
    )


def state(model, schema):
    """The document this render serialises, in the order `renders.md` fixes."""
    chosen = overrides(model)
    body = full_state(schema, chosen)
    ordered = {k: body[k] for k in CODERABBIT_TOP_LEVEL if k in body}
    for key in body:
        if key not in ordered:
            ordered[key] = body[key]
    return ordered


def render(model, doc):
    """`doc` as bytes, each path filter under a comment carrying its reason.

    `renders.md` § `reviews.path_filters` requires one per entry, for the
    reason `repo-toml.md` § `[exclusions]` gives for requiring the key at all:
    an exclusion with no stated reason is indistinguishable from a mistake at
    the next read.
    """
    node = dict(doc)
    reviews = node.get("reviews")
    if isinstance(reviews, dict) and reviews.get("path_filters"):
        reasons = {"!" + e["glob"]: e["reason"] for e in model.exclusions}
        reviews = dict(reviews)
        reviews["path_filters"] = [
            yamlemit.Commented(entry, reasons[entry]) for entry in reviews["path_filters"]
        ]
        node["reviews"] = reviews
    head = [
        CODERABBIT_SCHEMA_LINE,
        model.marker("hash"),
        "# This file is full state, not a delta: every key the vendored schema",
        "# defines a default for is written. An organization or workspace global",
        "# override, if one exists, outranks this file entirely.",
        "",
    ]
    return "\n".join(head) + yamlemit.document(node)
