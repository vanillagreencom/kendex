# Settings a package declares

A package ships a `kendex.settings.toml.example` at its root for the keys it
wants seeded. On a project install kendex merges every key in that file's
`[env]` table, together with the comment block directly above it, into the
consuming repo's `kendex.settings.toml`. A key already present there is left
alone, value and all, so a reinstall never overwrites what someone edited.

Not every key a package reads belongs in that file. A key it documents but
does not seed — an opt-in that ships a working default, an override seam —
lives in the package's own README, which the marketplace page renders. What
follows governs the keys a template carries.

Start from
[`templates/kendex.settings.toml.example`](templates/kendex.settings.toml.example).

## The grammar

One `[env]` table. A comment block sits immediately above its key with no
blank line between them — a blank line there means the key seeds without its
explanation, and that comment is what the consumer reads beside the key in
their own settings file. Every value is a single-line double-quoted string
containing no `"` and no `\`. Assignments outside `[env]` are ignored.

The two files treat a repeated key differently. In the consumer's
`kendex.settings.toml`, a duplicate assignment inside `[env]` fails the load.
In your template it does not: seeding takes the first declaration of a key
and drops every later one without a word, so a key written twice ships
whichever copy comes first. Write each key once.

## Naming

Prefix keys with the package name in upper-snake — `REVIEW_GATE_MODE` for a
package named `review-gate`. This is a convention, not something the check
enforces: a package that deliberately ships a companion package's key is
legitimate.

## Where a value comes from

Scripts read the `[env]` table with one precedence, highest first:

1. the process environment
2. `.env.local`
3. `.kendex/settings.toml`
4. `kendex.settings.toml`
5. the built-in default

A key may hold itself to a different policy — refusing every project file,
skipping the dotenv layer, or letting a project file outrank an inherited
environment value — as long as its own comment says so.

## Secrets are not settings

Ship only values that are safe to commit. A key whose value must stay out of
git — a token, a credential, a personal identifier — never appears as an
assignment in the template. Document it in the package's README as "set `X`
in `.env.local`" instead; the marketplace page renders that README.
