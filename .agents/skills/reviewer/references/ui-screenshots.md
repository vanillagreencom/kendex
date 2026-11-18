# Screenshots

A `needs-ui-review` review judges each changed view from this set. The round that changes the view captures it and lists it in its summary.

- Each changed view has an actual before image from the base revision and an actual after image from HEAD, in every theme the app has: dark and light where it has both.
- Where the view did not exist at the base revision, the before image is the actual comparable state there, such as the empty or missing-feature state, identified as that state. Never a fabricated blank.
- Each image keeps its comparison conditions: view and state, before or after, the revision it was captured from, theme, and viewport, scale or platform where they matter. A pair whose conditions differ says which one changed. An image is never relabelled as another revision's.
- Each image is a file where the repository's own capture procedure puts it, and under the worktree's `tmp/ui-shots/` only where the repository names no directory. It is listed on its own line of the round's summary as `[PATH]` - [View], [before|after], [THEME].
- A later round that changes the view again recaptures its after images and lists the view's full set, carrying the earlier round's before images with their original revision and conditions.
- A view missing any image of its set cannot be judged in that theme. When no actual comparable before image exists, the evidence stays incomplete: the blocker names the cause and the view's conditions, and only the owner's decision on that case, through the caller's owner-decision route, settles it. No after-only image stands in by default.
