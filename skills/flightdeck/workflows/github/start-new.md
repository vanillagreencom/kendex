# Workflow: `github start new` — Create GitHub Issue + Launch

Create a new GitHub issue, then enter `workflows/github/start.md` for the spawned worktree session.

**Inputs**: optional `[TITLE]`, optional `--repo <OWNER/REPO>`.

**Pre-conditions**:
- `$TMUX` set.
- `github` and `worktree` skills available. Do not load `linear` or `project-management`.
- `gh` authenticated against the target repo.

**Post-condition**: a GitHub issue exists and is launched through `github start <N>`.

---

## § 1: Gather intent

1. If `[TITLE]` was supplied, set `TITLE`.
2. Otherwise ask: `What GitHub issue should be created?` First line is `TITLE`; remaining lines are `DESCRIPTION_NOTES`.
3. Ask for any extra body/details if `DESCRIPTION_NOTES` is empty.

---

## § 2: Resolve repo

Resolve repo exactly as `workflows/github/start.md` § 1:

1. Prefer `--repo <OWNER/REPO>`.
2. Else parse `git config --get remote.origin.url`.
3. Else `gh repo view --json nameWithOwner --jq .nameWithOwner`.

Any `gh` failure follows the GitHub lane retry rule: retry once after 2s, then set `paused_for_user` with `reason="gh-cli-unavailable"`, command, and stderr.

---

## § 3: Create issue

Create the issue through `gh`:

```bash
gh issue create --repo <OWNER/REPO> --title "<TITLE>" --body "<DESCRIPTION_NOTES>"
```

Capture the resulting issue URL and number. If `gh issue create` fails, retry once after 2s; on second failure pause with `reason="gh-cli-unavailable"`.

Output:

<output_format>
Created GitHub issue <OWNER/REPO>#<N> — <TITLE>
<URL>
</output_format>

---

## § 4: Launch

Invoke `workflows/github/start.md <N>` with the same repo and launch-profile context. The spawned child receives the self-contained prompt from `github/start.md`; it never receives a flightdeck supervisor invocation.

## Returns

To `workflows/github/start.md`.