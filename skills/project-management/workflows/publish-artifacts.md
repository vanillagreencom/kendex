# Publish Planning Artifacts

Run after a run's planned tracker mutations, to publish its planning artifacts. [references/planning-artifacts.md](../references/planning-artifacts.md) selects each artifact's source issue, resolves its readable path and states the missing and unpublished cases.

## Linear

1. Attach each produced artifact and each cited planning input once, to its source issue.
   - One that already sits on its source issue is not uploaded again.
   - After the planned mutations for that issue, run `issues update [ISSUE_ID] --attach [PATH]`, repeated per file, as an attach-only call.
   - Include companion files needed to read the artifact, such as roadmap JSON and research metadata.
2. Keep its returned `attachments[]` entries.
3. Add an `**Artifacts**` list to the issue description: one `[repository-relative path](url)` link per entry.
4. Every other issue the run creates or updates that cites the artifact carries the same links in its own `**Artifacts**` list and uploads nothing.
5. Replace the prior link for the same path.
6. Preserve links to other inputs. Those links identify the published version even when older attachments share the path.
7. Verify every attachment and description write before reporting completion.

## GitHub

Put each produced text artifact, and the text of each cited planning input needed for pickup, on its source issue.

- A GitHub audit writes it into the body of the issue it creates or updates.
- Any other run, such as one that hands a fresh plan to another checkout, posts one comment per file on the source issue:
  1. Write a body file whose first line is the artifact's repository path and whose rest is its text.
  2. Run `gh issue comment [N] --repo [OWNER/REPO] --body-file [BODY_FILE]`.

Verify every body and comment write before reporting completion.
