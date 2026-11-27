# Directed change

The contract for an owner-directed small change: who makes it, where it runs, what checks it, and what the overseer does when its run escapes. [lane-launch.md § Item Tier](lane-launch.md#item-tier) sends the overseer here. The overseer runs the change itself through [micro.md](../workflows/micro.md) as `micro directive-[ID]`.

- A bare § names a section of this file. A section of micro.md is named with its file name.
- Every command here keeps micro.md's bindings: `[MAIN_REPO_ROOT]`, `[WT_PATH]`, `[BASE_BRANCH]`, `[BRANCH]` and `[PR_NUMBER]`.

## Who makes it

Read when an owner note asks for a small change that has no tracker item.

- The change's key is `directive-[ID]`. `[ID]` is the id of the note that directed it ([oversee-events.md § `owner-note`](oversee-events.md#owner-note)).
- The overseer makes the change itself, with no lane or internal review.
- The directive is the acceptance. micro.md § 2 step 7 records it on the item's round.
- The repository's own rules still apply: its commit chain, its required review and checks, and the paths micro.md § Escape condition 3 refuses.

A note from the owner or Jarvis that says "quick change" takes this directive route for Markdown or settings that run nothing themselves. On any host, the overseer makes the edit in a throwaway worktree or scratch clone. Keep edits out of the main checkout. Only the commit hooks' light checks run locally for the edit. If the request needs a script, workflow, hook, test or source file, or needs a separate local check, file it as a tracker item by the two steps below. If a later step would need a path outside that scope, a separate local check or a worker, take [§ Escape](#escape).

When the overseer app authors a proved quick change's pull request, follow [micro.md § 4](../workflows/micro.md#4-arm-and-wait) for Copilot approval and the repository's merge route.

For an ordinary directive, the overseer makes the change in its own checkout, on the control host or local. The cost of the change's check decides whether the overseer or a lane makes it. The kind of file never decides for an ordinary directive.

- If the commit chain checks the change in its diff-scoped pass, the overseer makes it through micro.md.
- If the check needs a build or a test run, a lane makes the change in its own sandbox. A lane is keyed by a tracker item, so `directive-[ID]` never runs as a lane.
  1. The overseer files the change as a tracker item from the directive, as it files an item an `owner-note` asks for ([oversee-events.md § File one item alone](oversee-events.md#file-one-item-alone)).
  2. That item launches under its own key, at the tier [lane-launch.md § Item Tier](lane-launch.md#item-tier) assigns it. It takes neither the directive's branch nor its pull request. Its lane makes the change again from the item.

## Escape

Read when the overseer's run of a directed change ends at a micro.md § Escape condition, or at a stop [lane-launch.md § Item Tier](lane-launch.md#item-tier) sends here.

If a quick change has a pull request, run [merge-pr-restack.md § Unarm at a stop](../workflows/merge-pr-restack.md#unarm-at-a-stop) before handing it back. Bind `[STATE_KEY]` to the directive key and `[STOP_DIR]` to `[WT_PATH]/tmp`. A refusal that leaves the pull request armed also keeps the checkout.

The run carries neither its branch nor its pull request over. The overseer files the change as a tracker item through [oversee-events.md § File one item alone](oversee-events.md#file-one-item-alone). The input file's `description` holds the directive's text and the captured changes in fenced `diff` blocks.

For a quick change, capture the whole scratch edit before filing or cleaning up, even before the first commit:

1. Read `git -C [WT_PATH] status --porcelain`. For any new path Git lists as untracked, run `git -C [WT_PATH] add -N -- [NEW_PATH]...` so the unstaged diff includes it.
2. Bind `[DIFF_BASE]` from `git -C [WT_PATH] merge-base origin/[BASE_BRANCH] HEAD`. Include `git -C [WT_PATH] diff --binary --cached [DIFF_BASE]` for committed and staged changes, then `git -C [WT_PATH] diff --binary` for unstaged and new changes.
3. If a command fails or the patches omit any scratch edit, keep the checkout and report what could not be captured.

For an ordinary directive, the diff is:

- at condition 4, the edit the refused commit leaves staged: `git -C [WT_PATH] diff --cached`;
- once a commit stands at any other stop: `git -C [WT_PATH] diff [BASE_BRANCH]...[BRANCH]`;
- before the edit, including condition 2: nothing.

Then:

1. Where a pull request exists, close it. For a quick change, detach its scratch checkout from `[BRANCH]` first. Run the close from `[WT_PATH]` to delete its branch on GitHub and in the checkout:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr close [PR_NUMBER] --delete-branch
   ```

2. For a quick change, remove the scratch checkout once the filed item holds the diff and any pull request is closed. Delete its local directive branch if it remains. For an ordinary directive with no pull request, return the checkout to `[BASE_BRANCH]` and delete the branch once the filed item holds the diff:
   1. At condition 4 only, first run `git -C [MAIN_REPO_ROOT] reset --hard`.
   2. Run `git -C [MAIN_REPO_ROOT] checkout [BASE_BRANCH]`.
   3. Run `git -C [MAIN_REPO_ROOT] branch -D [BRANCH]`.
3. The filed item launches as a lane through [lane-launch.md § Lane directive](lane-launch.md#lane-directive), at the tier § Item Tier there assigns its body. It never launches through micro.md § Escape's tracker-item routes, and never on the control host.
4. The directive's run records no `review_floor`.
5. A `fallback cause=no-files` on the filed item's lane head is that lane's own condition 9. The lane records it and relaunches under the item's key.
