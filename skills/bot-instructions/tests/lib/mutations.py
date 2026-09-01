"""Renderer-regression controls.

Several rejection clauses exist to catch a **renderer** regression rather than
a bad input: `path_filters` losing its `!`, an ordinary surface gaining an
`excludeAgent`, a Macroscope `include` going missing, a serializer dropping
one derived tree from every destination. No `bot-instructions.toml` can
produce those, so a control for them has to break the renderer.

This does it in-process, against the real modules and a real repository: one
render function is replaced, the same `validate()` runs, and the assertion is
on the validator's own identity. There is no fault-injection seam in the
shipped code — a production switch that makes the generator misbehave is one
more thing that can be left on.

Run by `renderer-regressions.test.sh`, which supplies a rendered fixture repo.
"""

import contextlib
import re
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
PACKAGE = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(PACKAGE, "scripts"))

from lib import (  # noqa: E402
    model as model_mod,
    render_coderabbit,
    render_markdown,
    render_qodo,
    run,
    tree,
)

PASS = 0
FAIL = 0


def report(ok_, label, detail=""):
    global PASS, FAIL
    if ok_:
        PASS += 1
        print(f"  ok   {label}")
    else:
        FAIL += 1
        print(f"  FAIL {label}")
        if detail:
            print(f"       {detail}")


@contextlib.contextmanager
def patched(module, name, replacement):
    original = getattr(module, name)
    setattr(module, name, replacement)
    try:
        yield
    finally:
        setattr(module, name, original)


def _context(repo, verb="render"):
    return run.Context(
        repo,
        tree.Worktree(repo),
        tree.Worktree(PACKAGE),
        ("SKILL.md", "schemas/renders.md"),
        verb,
        ("SKILL.md", "schemas/renders.md"),
    )


def findings(repo, verb="check"):
    ctx = run.Context(
        repo,
        tree.Worktree(repo),
        tree.Worktree(PACKAGE),
        ("SKILL.md", "schemas/renders.md"),
        verb,
        ("SKILL.md", "schemas/renders.md"),
    )
    return run.validate(ctx)


def control(repo, want, label, module, name, replacement, also=()):
    """One red control: the named validator reds, and the set is exactly known.

    A fixture that also trips an unrelated validator reds for the wrong reason
    and reads as coverage, so the assertion is an exact set match. Where one
    mutation genuinely breaches two clauses — dropping the `!` from a
    `path_filters` entry also empties the exclusion list that surface carries
    — `also` names the second, and a run whose set stops matching fails.

    Every control runs the `render` verb: `drift` is skipped there by design,
    and a renderer regression would otherwise red it on every fixture, which
    is the confound the isolation rule exists to prevent.
    """
    with patched(module, name, replacement):
        try:
            found = findings(repo, "render")
        except Exception as exc:  # a render that cannot produce bytes at all
            report(False, label, f"the render raised before any validator ran: {exc}")
            return
    fired = sorted({f.validator for f in found})
    expected = sorted({want} | set(also))
    if fired == expected:
        report(True, label)
    else:
        report(False, label, f"expected exactly {expected}; fired: {fired or 'nothing'}")


def says(repo, want, label, module, name, replacement, needle, absent=None):
    """A red control that also reads its own message.

    Three findings this package emits are the right validator with the wrong
    cause — a parse failure arriving as a set mismatch, an unreadable
    frontmatter block arriving as an absent one. Asserting only the validator
    identity would pass on exactly the message the fix replaced, so these
    assert the sentence a reader acts on.
    """
    with patched(module, name, replacement):
        try:
            found = findings(repo, "render")
        except Exception as exc:  # noqa: BLE001
            report(False, label, f"the render raised before any validator ran: {exc}")
            return
    mine = [f for f in found if f.validator == want]
    stray = [f for f in found if absent and absent in f.message]
    if not mine:
        report(False, label, f"{want} did not fire; fired: "
                             f"{sorted({f.validator for f in found}) or 'nothing'}")
    elif not any(needle in f.message for f in mine):
        report(False, label, f"expected {needle!r}; got: {mine[0].message[:160]}")
    elif stray:
        # The other half, and the one a needle alone cannot prove: the failure
        # must not ALSO arrive dressed as an ordinary finding somewhere else.
        report(False, label, f"a finding still carries {absent!r}: {stray[0].message[:160]}")
    else:
        report(True, label)


def _wrong_cause(repo):
    """A failure must not arrive dressed as an ordinary finding."""
    qodo = render_qodo.render

    def broken_toml(m):
        return qodo(m).replace("[ignore]", "[ignore] this line is not TOML")

    says(repo, "exclusion-consistency",
         "an unreadable exclusion surface is named as unreadable, not as a stray glob",
         render_qodo, "render", broken_toml,
         "[ignore] glob cannot be read", absent="<unreadable:")

    surface = render_markdown.macroscope_surface

    def broken_frontmatter(m, s):
        text = surface(m, s)
        head, _, rest = text.partition("\n---\n")
        return head.replace("include:", "include: [unclosed,") + "\n---\n" + rest

    says(repo, "macroscope-render",
         "frontmatter that will not parse says so, rather than reading as absent",
         render_markdown, "macroscope_surface", broken_frontmatter,
         "does not parse")


def main(repo, no_derive):
    _coderabbit(repo)
    _copilot(repo)
    _qodo(repo)
    _macroscope(repo)
    _exclusions(repo)
    _wrong_cause(repo)
    _unconditional(no_derive)
    print(f"mutations.py: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


def _coderabbit(repo):
    control(repo, "coderabbit-filters",
            "a path_filters entry that lost its `!` turns the list into an allowlist",
            render_coderabbit, "path_filters",
            lambda m: [e["glob"] for e in m.exclusions],
            also=("exclusion-consistency",))
    control(repo, "coderabbit-filters",
            "a path_filters entry outside the dialect matches nothing in sparse-checkout",
            render_coderabbit, "path_filters",
            lambda m: ["!{a,b}/**"] + ["!" + e["glob"] for e in m.exclusions],
            also=("exclusion-consistency",))

    original = render_coderabbit.full_state

    def drop_nested(schema, chosen, path=""):
        built = original(schema, chosen, path)
        # A nested option dropped under an existing object: the top-level
        # property is still present, so a root-only completeness clause passes
        # and the setting silently resumes resolving down the ladder.
        if path == "" and "knowledge_base" in built:
            built["knowledge_base"].pop("opt_out", None)
        return built

    def drop_root(schema, chosen, path=""):
        built = original(schema, chosen, path)
        if path == "":
            built.pop("issue_enrichment", None)
        return built

    control(repo, "coderabbit-schema",
            "a nested option the vendored schema defines, dropped under an existing object",
            render_coderabbit, "full_state", drop_nested)
    def unknown_root_key(schema, chosen, path=""):
        built = original(schema, chosen, path)
        if path == "":
            # The root schema sets `additionalProperties: false`, so CodeRabbit
            # discards the whole file over one misspelled top-level key and
            # reviews with resolved defaults, saying nothing on the pull
            # request. That is the silent failure this validator leads with.
            built["reviews_"] = built.get("reviews", {})
        return built

    def wrong_type(schema, chosen, path=""):
        built = original(schema, chosen, path)
        # A boolean with no `enum` beside it, so `type` is the only clause
        # that can catch this. `language` would have reded on its enum too,
        # and the control would then pass with the type clause deleted.
        if path == "" and "early_access" in built:
            built["early_access"] = "false"
        return built

    control(repo, "coderabbit-schema",
            "a top-level property the vendored schema defines, dropped by the render",
            render_coderabbit, "full_state", drop_root)
    control(repo, "coderabbit-schema",
            "a top-level key the vendored schema does not define",
            render_coderabbit, "full_state", unknown_root_key)
    control(repo, "coderabbit-schema",
            "a defined property emitted at the wrong type",
            render_coderabbit, "full_state", wrong_type)


def _copilot(repo):
    original = render_markdown.instructions_file

    def without_exclude_agent(m, surface):
        return original(m, dict(surface, reviewer_only=False))

    def wrong_exclude_agent(m, surface):
        return original(m, surface).replace('"cloud-agent"', '"code-review"')

    def exclude_agent_on_ordinary(m, surface):
        # The `docs` surface is not reviewer_only, so the render emits no key
        # there; a regression that emits `code-review` would hide the
        # surface's path rules from code review with the file parsing.
        return original(m, dict(surface, reviewer_only=surface["name"] == "docs"))

    def no_apply_to(m, surface):
        return original(m, surface).replace('applyTo: "src/tests/**"\n', "")

    def empty_apply_to(m, surface):
        return original(m, surface).replace('applyTo: "src/tests/**"', 'applyTo: "  "')

    def array_apply_to(m, surface):
        return original(m, surface).replace(
            'applyTo: "src/tests/**"', "applyTo:\n  - \"src/tests/**\"")

    control(repo, "copilot-frontmatter",
            "a reviewer_only surface rendered with no excludeAgent",
            render_markdown, "instructions_file", without_exclude_agent)
    control(repo, "copilot-frontmatter",
            "a reviewer_only surface rendered with excludeAgent code-review",
            render_markdown, "instructions_file", wrong_exclude_agent)
    control(repo, "copilot-frontmatter",
            "an ordinary surface rendered with an excludeAgent at all",
            render_markdown, "instructions_file", exclude_agent_on_ordinary)
    control(repo, "copilot-frontmatter",
            "a generated .instructions.md with no applyTo matches nothing",
            render_markdown, "instructions_file", no_apply_to)
    control(repo, "copilot-frontmatter",
            "an applyTo that is whitespace",
            render_markdown, "instructions_file", empty_apply_to)
    control(repo, "copilot-frontmatter",
            "an applyTo emitted as a YAML array rather than one string",
            render_markdown, "instructions_file", array_apply_to)


def _qodo(repo):
    original = render_qodo._guidance

    def drop_from_extra(m, column, with_summary=True):
        text = original(m, column, with_summary)
        if column == "pr_agent extra":
            text = text.replace(m.block("trust-model"), "")
        return text

    def drop_from_review_agent(m, column, with_summary=True):
        text = original(m, column, with_summary)
        if column == "pr_agent compliance":
            text = text.replace(m.block("trust-model"), "")
        return text

    def empty_extra(m, column, with_summary=True):
        return "" if column == "pr_agent extra" else original(m, column, with_summary)

    control(repo, "qodo-parity",
            "a block present in the [review_agent] keys and dropped from extra_instructions",
            render_qodo, "_guidance", drop_from_extra)
    control(repo, "qodo-parity",
            "a block present in extra_instructions and dropped from the [review_agent] keys",
            render_qodo, "_guidance", drop_from_review_agent)
    # Emptying the section drops the exclusion paths the routing table marks
    # `pr_agent extra` as carrying, which is a second clause genuinely
    # breached rather than a confound.
    control(repo, "qodo-parity",
            "a review-role pr_commands verb whose section carries no guidance",
            render_qodo, "_guidance", empty_extra,
            also=("exclusion-consistency",))
    _qodo_role(repo)


def _qodo_role(repo):
    """The role guard, which no fixture's verb list can reach on its own.

    `repo-toml.md` § `[cadence]` gives three verbs the role `not review`, and
    the clause above skips them: their sections are read by a command that
    does not review, so guidance missing there is not a parity failure. No
    `bot-instructions.toml` exercises the skip — a verb list is legal whatever
    its roles, and the fixture's own render fills both sections, so the clause
    is silent for every verb and deleting the guard changes nothing.

    Both halves therefore run the SAME empty section: `/agentic_review` and
    `/describe` both read the `[review_agent]` keys, so role is the only thing
    that differs. The review one must fire and the other must not.
    """
    from lib import validators_bytes as vb  # noqa: PLC0415

    ctx = _context(repo)
    text = ctx.build.files[".pr_agent.toml"]
    blanked = re.sub(r'(?ms)^(issues_user_guidelines|compliance_user_guidelines) = """.*?"""',
                     r'\1 = """\n"""', text)
    if blanked == text:
        report(False, "the role guard skips a verb that does not review",
               "the fixture's [review_agent] keys are not the shape this blanks")
        return
    ctx.build.files[".pr_agent.toml"] = blanked
    seen = {}
    for verb in ("/agentic_review", "/describe"):
        ctx.config.cadence["qodo_commands"] = [verb]
        out = []
        vb.qodo_parity(ctx, out)
        seen[verb] = any("whose role is" in f.message for f in out)
    if seen["/agentic_review"] and not seen["/describe"]:
        report(True, "the role guard skips a verb that does not review")
    else:
        report(False, "the role guard skips a verb that does not review",
               f"review verb fired: {seen['/agentic_review']}; "
               f"non-review verb fired: {seen['/describe']}")


def _macroscope(repo):
    original = render_markdown.macroscope_surface

    def no_frontmatter(m, surface):
        return original(m, surface).split("---\n", 2)[-1]

    def extra_key(m, surface):
        return original(m, surface).replace("include:", "waitsFor:\n  - \"x\"\ninclude:")

    def not_an_array(m, surface):
        return original(m, surface).replace('include:\n  - "src/tests/**"', 'include: |2-\n  x')

    def empty_body(m, surface):
        text = original(m, surface)
        return text[: text.index("-->") + 4] + "\n"

    def include_absent(m, surface):
        # The key gone, a valid mapping left behind. `no_frontmatter` above
        # strips the whole `---` block and lands on the front-is-None branch,
        # which is a DIFFERENT clause: this is the one validators.md calls the
        # one that matters, because omitted frontmatter applies repo-wide and
        # a path-scoped surface silently widens to the whole repository.
        return original(m, surface).replace(
            'include:\n  - "src/tests/**"', 'exclude:\n  - "src/generated/**"')

    def include_empty(m, surface):
        return original(m, surface).replace('include:\n  - "src/tests/**"', "include: []")

    control(repo, "macroscope-render",
            "a correctness file whose frontmatter went missing applies repo-wide",
            render_markdown, "macroscope_surface", no_frontmatter)
    control(repo, "macroscope-render",
            "a frontmatter key other than include or exclude",
            render_markdown, "macroscope_surface", extra_key)
    control(repo, "macroscope-render",
            "an include that is not a YAML array of strings",
            render_markdown, "macroscope_surface", not_an_array)
    control(repo, "macroscope-render",
            "a correctness file with no instruction text below the marker",
            render_markdown, "macroscope_surface", empty_body)
    control(repo, "macroscope-render",
            "a correctness file whose include key went missing applies repo-wide",
            render_markdown, "macroscope_surface", include_absent)
    control(repo, "macroscope-render",
            "a correctness file whose include is empty",
            render_markdown, "macroscope_surface", include_empty)

    ignore = render_markdown.macroscope_ignore

    def stray_line(m):
        return ignore(m) + "\nnot a glob because it has spaces\n"

    def unclosed_comment(m):
        return ignore(m).replace("<!-- fixtures", "<!-- fixtures\ncontinued")

    control(repo, "macroscope-render",
            "an ignore.md line that is neither a glob nor a single-line comment",
            render_markdown, "macroscope_ignore", stray_line,
            also=("exclusion-consistency",))
    control(repo, "macroscope-render",
            "an ignore.md comment that does not close on its own line",
            render_markdown, "macroscope_ignore", unclosed_comment,
            also=("exclusion-consistency",))


def _exclusions(repo):
    original = model_mod.build

    def drop_one_everywhere(tree_, config, doctrine, spec_paths):
        m = original(tree_, config, doctrine, spec_paths)
        # A serialization or routing bug drops the same derived tree from
        # every destination while the independent derivation still holds it.
        # The cross-surface clause agrees with itself here; only the
        # comparison against a fresh derivation sees it.
        m.exclusions = [e for e in m.exclusions if e["glob"] != ".claude/agents/**"]
        return m

    control(repo, "exclusion-consistency",
            "a serializer that drops one derived tree from every destination, on render",
            model_mod, "build", drop_one_everywhere)

    ignore = render_markdown.macroscope_ignore

    def drop_one_surface(m):
        text = ignore(m)
        return "\n".join(ln for ln in text.split("\n") if ln != ".claude/agents/**")

    control(repo, "exclusion-consistency",
            "an entry excluded on one rendered surface and not on another",
            render_markdown, "macroscope_ignore", drop_one_surface)

    region = render_markdown.agents_region_body

    def strip_paths(m):
        text = region(m)
        for entry in m.exclusion_globs:
            text = text.replace(entry, "")
        return text

    control(repo, "exclusion-consistency",
            "a render that drops the paths from the one surface Codex reads",
            render_markdown, "agents_region_body", strip_paths)

    guidance = render_qodo._guidance

    def strip_from(column_name):
        # Asking whether a glob appears anywhere in `.pr_agent.toml` is
        # answered by `[ignore] glob` beside the guidance, so a render that
        # dropped the paths from the guidance keys themselves passed. These
        # two are the destinations that could not red.
        def replacement(m, column, with_summary=True):
            text = guidance(m, column, with_summary)
            if column == column_name:
                for entry in m.exclusion_globs:
                    text = text.replace(entry, "")
            return text
        return replacement

    control(repo, "exclusion-consistency",
            "a render that drops the paths from [review_agent] issues_user_guidelines",
            render_qodo, "_guidance", strip_from("pr_agent issues"))
    control(repo, "exclusion-consistency",
            "a render that drops the paths from [pr_reviewer] extra_instructions",
            render_qodo, "_guidance", strip_from("pr_agent extra"))

    control(repo, "exclusion-consistency",
            "a rendered exclusion surface emitted empty, which is an empty list "
            "and not an absent mechanism",
            render_markdown, "macroscope_ignore", lambda m: "")


def _unconditional(repo):
    """The clauses `[exclusions] derive_render` does not gate, with it false.

    `derive_render` defaults to false and `tests/fixtures/canonical.toml` was
    the sole place it was ever set, so every clause below ran only on the
    fixture that turned the flag on — while the flag gated all four. Each
    control here is the same mutation as its counterpart above against a
    repo on the default, where `[[exclusions.path]]` is the whole set.
    """
    ignore = render_markdown.macroscope_ignore

    def drop_first_surface(m):
        text = ignore(m)
        first = m.exclusion_globs[0]
        return "\n".join(ln for ln in text.split("\n") if ln != first)

    control(repo, "exclusion-consistency",
            "with derive_render false: an entry excluded on one surface and not another",
            render_markdown, "macroscope_ignore", drop_first_surface)

    region = render_markdown.agents_region_body

    def strip_paths(m):
        text = region(m)
        for entry in m.exclusion_globs:
            text = text.replace(entry, "")
        return text

    control(repo, "exclusion-consistency",
            "with derive_render false: a render that drops the paths from AGENTS.md",
            render_markdown, "agents_region_body", strip_paths)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
