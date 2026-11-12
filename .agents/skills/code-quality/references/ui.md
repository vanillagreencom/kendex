# Views and UI copy

Standard practice for a changed view and its copy, in any UI stack. The project's design-system doc, where it names one, sets the visual bar and supplies the tokens.

- Use the design system's tokens for color, spacing, radius and type, never a one-off value.
- Give each view a clear hierarchy: primary content stands out and secondary content recedes.
- Keep spacing even.
- Read the finished change as a first-time user, copy included.

## UI copy

These rules hold for every string a view shows. A string that breaks one is a finding to fix, and the fix can be to delete it.

- Write only the text a user needs to act or to understand what happened; leave a slot empty rather than fill it. Under the heading "Projects", delete "Manage all your projects in one place."
- Say each thing once. No body text or hint repeats what a title, label, button or icon already says, or explains how to use a control that shows what it does. Beside a "Confirm" button, delete "Use the button or key to confirm."
- Use plain, short, specific words, in the user's terms. Write "Turn on notifications", not "Enable webhook delivery".

| Element | Rule | Example |
|---|---|---|
| Label | A short noun phrase that names the field. | "Email", not "Enter your email address:" |
| Button | A specific verb for what the button does, with its object where no title names it. | "Save API key", not "Submit" |
| Dialog | The body adds only what the title and buttons do not say, or is absent. | Title "Rename project", a name field and a "Rename" button; no "Enter a new name for this project." |
| Confirmation | The title asks the action and its object, the body states only a consequence the user cannot undo, and the button repeats the title's verb. | Title "Delete 3 files?", body "This can't be undone.", button "Delete"; never "Are you sure?" |
| Hint | One short sentence that answers a question most users have and the label does not answer; otherwise none. | Under "Date of birth": "For example, 27 3 2007" |
| Empty state | One next action, and only what the screen does not already show. | Under the heading "Projects": a "Connect repository" button, not "No projects yet." |
| Error | What failed and how to fix it, with no blame, apology or guessed cause. | "That name is already in use. Choose another.", not "Invalid name" |

## Screenshots

The screenshot set a UI review judges a changed view from is the reviewer skill's, in its `workflows/qa-review.md` § Screenshots.
