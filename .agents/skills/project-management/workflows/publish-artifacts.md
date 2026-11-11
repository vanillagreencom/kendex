# Publish Planning Artifacts

Run after a run's planned tracker mutations, to publish its planning artifacts. [SKILL.md § Planning artifacts](../SKILL.md#planning-artifacts) selects each artifact's source issue, resolves its readable path and states the missing and unpublished cases.

## Linear

1. Attach each produced artifact and each cited planning input once, to its source issue; one that already sits on its source issue is not uploaded again. After the planned mutations for that issue, run `issues update [ISSUE_ID] --attach [PATH]`, repeated per file, as an attach-only call. Include companion files needed to read the artifact, such as roadmap JSON and research metadata.
2. Keep its returned `attachments[]` entries and add an `**Artifacts**` list to the issue description: one `[repository-relative path](url)` link per entry.
3. Every other issue the run creates or updates that cites the artifact carries the same links in its own `**Artifacts**` list and uploads nothing.
4. Replace the prior link for the same path and preserve links to other inputs. Those links identify the published version even when older attachments share the path.
5. Verify every attachment and description write before reporting completion.

## GitHub

For a GitHub audit, put the produced text artifact in the created or updated issue body, and include the text of any cited planning input needed for pickup.
