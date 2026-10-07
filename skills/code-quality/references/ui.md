# Views and UI copy

The polish bar for a changed view, in any UI stack, and the screenshot set that shows it. The project's design-system doc, where it names one, supplies the tokens.

- Build to the polish of Vercel's web app or a standard modern consumer app.
- Use the design system's tokens for color, spacing, radius and type, never a one-off value.
- Give each view a clear hierarchy: primary text, secondary text in grey, names in chips.
- Keep spacing even and copy plain and short.
- Read the finished change as a first-time user, copy included.

## Screenshots

A round that must show its changed views captures this set for each one, and a UI review judges the view from it.

- A before shot from the base revision and an after shot from HEAD, in every theme the app has: dark and light where it has both.
- Each shot is a file under the worktree's `tmp/ui-shots/`, listed on its own line of the round's summary as `tmp/ui-shots/[FILE]` - [View], [before|after], [THEME].
- A later round that changes the view again recaptures its after shots and lists the view's full set, carrying the earlier round's before shots.
- A view missing any shot of its set cannot be judged in that theme.
