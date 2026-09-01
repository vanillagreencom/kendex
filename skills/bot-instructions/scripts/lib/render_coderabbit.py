"""`.coderabbit.yaml`: full state, driven by the vendored schema.

An unset key resolves down a precedence ladder this package does not control,
so the render writes full state including keys that match their schema
default. **Full state is every property the vendored schema defines a default
for, at every depth** — a property the vendor gives no default has no
"resolves down the ladder" semantics to state, and writing one would assert a
value the vendor never chose.

Walking the schema rather than transcribing a key list is what makes that true
at every depth: the nested option a vendor adds arrives at its own default and
shows in the diff, instead of leaving a top-level property present while a
setting one level down silently resumes resolving. `coderabbit-schema`'s
completeness clause holds the walk to the schema in both directions.

OVERRIDES is where this package has an opinion. Everything else is the
vendor's default, written explicitly.
"""

from .constants import CODERABBIT_SCHEMA_LINE, CODERABBIT_TOP_LEVEL, DEFAULT_TONE
from .model import exclude_sentence
from . import yamlemit


def tone(model):
    """`[tone] coderabbit` with newlines collapsed, emitted as a folded scalar.

    The 250-character cap is the vendored schema's own `maxLength`, so
    `coderabbit-schema` is its single enforcer and this does not carry a
    second copy of the number. Refusing here as well would give one bound two
    owners and no fixture could red exactly one of them.
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
        out.append({
            "path": "**",
            "instructions": model.block("render-out-of-scope").replace("\n", " ")
            + " Those paths here: " + ", ".join(model.exclusion_globs) + ".",
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


def full_state(schema, chosen, path=""):
    """Every property the schema defines a default for, at every depth."""
    props = schema.get("properties") or {}
    out = {}
    for key, sub in props.items():
        here = f"{path}.{key}" if path else key
        if here in chosen:
            out[key] = chosen[here]
            continue
        if sub.get("type") == "object" and sub.get("properties"):
            nested = full_state(sub, chosen, here)
            if nested or "default" in sub:
                out[key] = nested
            continue
        if "default" not in sub:
            continue
        out[key] = sub["default"]
    return out


def render(model, schema):
    body = full_state(schema, overrides(model))
    ordered = {k: body[k] for k in CODERABBIT_TOP_LEVEL if k in body}
    for key in body:
        if key not in ordered:
            ordered[key] = body[key]
    head = [
        CODERABBIT_SCHEMA_LINE,
        model.marker("hash"),
        "# This file is full state, not a delta: every key the vendored schema",
        "# defines a default for is written. An organization or workspace global",
        "# override, if one exists, outranks this file entirely.",
        "",
    ]
    return "\n".join(head) + yamlemit.document(ordered)
