# Workflow: `github start new` — Create GitHub Issue + Launch

Create a new GitHub issue, set up a worktree, and launch a GitHub issue session.

## Inputs

| Command | Flow |
|---------|------|
| `github start new` | § 1 → § 2 → § 3 |
| `github start new [TITLE]` | Skip title prompt → § 1 step 2 → § 2 → § 3 |

---

## 1. Gather Intent

1. **If title provided** as argument → set `TITLE`, skip to step 2.

   **Otherwise** → Ask user: "What do you want to work on?" (free text).

   Parse response: first line = `TITLE`, rest = `DESCRIPTION_NOTES`.

2. **Ask user**: "Brief description? (or press enter to skip)".

   If response provided → append to `DESCRIPTION_NOTES`.

3. **Ask user** for optional labels if the repo uses them: `No labels` | `Add labels`.

   If `Add labels`, capture comma-separated label names for `gh issue create --label`.

---

## 2. Create Issue

### 2.1 Build Body

Create a concise body from `DESCRIPTION_NOTES`:

```markdown
## Summary

[DESCRIPTION_NOTES or "Scope TBD."]

## Acceptance Criteria

- [ ] Implementation complete
- [ ] Tests/validation complete
- [ ] PR links this issue with `Fixes #[ISSUE_NUMBER]`
```

### 2.2 Create GitHub Issue

Run:

```bash
gh issue create --title "$TITLE" --body-file "$BODY_FILE" [--label "LABELS"]
```

Capture the returned URL, then resolve the issue number:

```bash
ISSUE_ID=$(printf '%s\n' "$ISSUE_URL" | sed -E 's#.*/issues/([0-9]+).*#\1#')
gh issue view "$ISSUE_ID" --json number,title,state,url,labels
```

If `gh issue create` fails, stop and surface stderr.

### 2.3 Output

<output_format>
GitHub issue created: #[ISSUE_ID] — [TITLE]
URL: [URL]
Labels: [LABELS or none]
</output_format>

---

## 3. Create Worktree & Launch

Invoke `⤵ workflows/github/start.md [ISSUE_ID] § 1-4 → end`.

The nested start workflow owns worktree checks, launch-profile selection, `open-terminal --tracker github`, and entry into `workflows/github/watch.md`.

---

## Returns

To the GitHub issue watch loop if launched, or to the user if manual launch was selected.
