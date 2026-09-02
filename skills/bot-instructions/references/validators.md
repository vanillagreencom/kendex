# Why validators

Every bot in this set fails silently. An over-limit `.coderabbit.yaml` is
discarded whole and the review runs with defaults. A `path_filters` entry
missing its `!` turns the list into an allowlist and stops reviewing the rest of
the repository. An `excludeAgent` typo loads reviewer doctrine into the working
agent. In each case the pull request looks reviewed.

Each validator names the silent failure it catches. Every rejection ships a
fixture carrying that defect and asserts the validator's own message. One
canonical render also stays green so a validator that rejects everything fails
the suite. Vendor web settings are outside every validator's reach and belong in
[checklist.md](checklist.md).
