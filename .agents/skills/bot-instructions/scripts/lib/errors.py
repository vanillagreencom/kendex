"""Failure types.

Every failure here fails a run. Nothing in this package warns: a warning on a
surface that fails silently is one more thing nobody reads.

`InputError` is the input-side family — a value this package will not render.
`Finding` is the validator-side one, and it carries the validator's own
identity, which § Controls requires a control to assert on.
"""


class BotInstructionsError(Exception):
    """Base for every failure this package raises."""


class SpecError(BotInstructionsError):
    """The spec copy is unusable: no version, no doctrine, a broken table."""


class InputError(BotInstructionsError):
    """A read input is missing, unparseable, or refused."""


class SourceUnavailable(InputError):
    """An input this run needs could not be read, and the reason is not absence.

    **A source that cannot answer raises; only a definite empty answer returns
    empty.** A reader that answers "nothing found" when it means "I could not
    tell" makes every validator above it report a clean pass on a repo nobody
    checked. Names the failing command and what it said.
    """

    def __init__(self, what, detail):
        super().__init__(f"{what}: {detail}")


class ManifestError(InputError):
    """The resolved install manifest is missing, unparseable, or declares no
    install. Its own type, so the run can attribute it to
    `exclusion-consistency` rather than matching on the message text."""


class RenderError(BotInstructionsError):
    """A render could not produce bytes, or a write phase failed."""


class Finding(BotInstructionsError):
    """One validator rejection.

    `validator` is the validator's own name as `validators.md` spells it, and
    it is what a control asserts on.
    """

    def __init__(self, validator, message, path=None):
        self.validator = validator
        self.message = message
        self.path = path
        where = f" [{path}]" if path else ""
        super().__init__(f"{validator}: {message}{where}")


class ValidationFailed(BotInstructionsError):
    """One or more findings. Carries every finding, not just the first."""

    def __init__(self, findings):
        self.findings = list(findings)
        body = "\n".join(f"  {f}" for f in self.findings)
        super().__init__(f"{len(self.findings)} finding(s):\n{body}")
