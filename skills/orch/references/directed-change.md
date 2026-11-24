# Directed change

The contract for an owner-directed small change: who makes it, where it runs, what checks it, and what the overseer does when its run escapes. [lane-launch.md § Item Tier](lane-launch.md#item-tier) sends the overseer here. The overseer runs the change itself through [micro.md](../workflows/micro.md) as `micro directive-[ID]`.

- A bare § names a section of this file. A section of micro.md is named with its file name.
- Every command here keeps micro.md's bindings: `[MAIN_REPO_ROOT]`, `[BASE_BRANCH]`, `[BRANCH]` and `[PR_NUMBER]`.

## Who makes it

Read when an owner's note asks for a small change, such as a settings line or a few lines of Markdown, that has no tracker item.

- The change's key is `directive-[ID]`. `[ID]` is the id of the owner's note that directed it ([oversee-events.md § `owner-note`](oversee-events.md#owner-note)).
- The overseer makes the change in its own checkout, on the control host or local. No lane runs it, and no internal review runs.
- The directive is the acceptance. micro.md § 2 step 7 records it on the item's round.
- The repository's own rules still apply: its commit chain, its required review and checks, and the paths micro.md § Escape condition 3 refuses.

The cost of the change's check decides whether the overseer or a lane makes it. The kind of file never decides.

- If the commit chain checks the change in its diff-scoped pass, the overseer makes it through micro.md.
- If the check needs a build or a test run, a lane makes the change in its own sandbox. A lane is keyed by a tracker item, so `directive-[ID]` never runs as a lane.
  1. The overseer files the change as a tracker item from the directive, as it files an item an `owner-note` asks for ([oversee-events.md § File one item alone](oversee-events.md#file-one-item-alone)).
  2. That item launches under its own key, at the tier [lane-launch.md § Item Tier](lane-launch.md#item-tier) assigns it. It takes neither the directive's branch nor its pull request. Its lane makes the change again from the item.

## Escape

Read when the overseer's run of a directed change ends at a micro.md § Escape condition, or at a stop [lane-launch.md § Item Tier](lane-launch.md#item-tier) sends here.

The run carries neither its branch nor its pull request over. The overseer files the change as a tracker item through [oversee-events.md § File one item alone](oversee-events.md#file-one-item-alone). The input file's `description` holds the directive's text and, after it, the change as made in a fenced `diff` block, so its lines stay lines. The diff is:

- at conditions 3 and 5 to 9, once a commit stands: `git -C [MAIN_REPO_ROOT] diff [BASE_BRANCH]...[BRANCH]`;
- at condition 4, the edit the refused commit leaves staged: `git -C [MAIN_REPO_ROOT] diff --cached`;
- at condition 2, which comes before the edit: nothing.

Then:

1. Where a pull request exists, at conditions 5 to 9, close it. The close deletes its branch on GitHub and in the checkout:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr close [PR_NUMBER] --delete-branch
   ```

2. Where no pull request exists, return the checkout to `[BASE_BRANCH]` and delete the branch, once the diff stands on the filed item:
   1. At condition 4 only, first run `git -C [MAIN_REPO_ROOT] reset --hard`.
   2. Run `git -C [MAIN_REPO_ROOT] checkout [BASE_BRANCH]`.
   3. Run `git -C [MAIN_REPO_ROOT] branch -D [BRANCH]`.
3. The filed item launches as a lane through [lane-launch.md § Lane directive](lane-launch.md#lane-directive), at the tier § Item Tier there assigns its body. It never launches through micro.md § Escape's tracker-item routes, and never on the control host.
4. The directive's run records no `review_floor`.
5. A `fallback cause=no-files` on the filed item's lane head is that lane's own condition 9. The lane records it and relaunches under the item's key.
