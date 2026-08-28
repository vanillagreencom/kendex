# Settings a skill declares

A skill ships a `kendex.settings.toml.example` at its root for the keys it
wants seeded. On a project install kendex reads that file's `[env]` table and
merges each key, together with the comment block directly above it, into the
consuming repo's `kendex.settings.toml`.

Seeding is a skill's alone. An agent, hook, command or MCP server that ships
one of these files installs normally and seeds nothing — the file is inert,
and no error says so. It runs on project scope for an enabled skill that at
least one harness here targets, and it runs before any skill tree is written:
a plan whose every rendering is refused still seeds. A global install seeds
nothing.

Not every key a skill reads belongs in that file. A key it documents but does
not seed — an opt-in that ships a working default, an override seam — is
explained in the skill's `SKILL.md`, which is the body a marketplace page
shows for a skill. A `README.md` beside it ships with the skill and appears in
the page's file list, but it is not what the page renders. For the other kinds
the rendered body is the package's one file: the agent's or command's markdown
after its frontmatter, and a hook script or MCP config whole, comments
included.

Start from
[`templates/kendex.settings.toml.example`](templates/kendex.settings.toml.example).

## What an install writes, and what it leaves

A key already assigned in the consumer's file is never seeded over, and no
install rewrites a value. The presence check is deliberately wider than what
the readers look at: an assignment of that key anywhere in the file, inside
`[env]` or not, counts as present and suppresses the insert.

Comment blocks are the one thing a later install may rewrite. The lock records,
per key, the skill that seeded it and a hash of the comment block seeding last
wrote. A revised template rewrites that block only while the on-disk text still
hashes to the record and the template belongs to the recorded owner. Anything
else — an edited comment, another skill's template — is preserved untouched, so
a consumer's own wording survives every refresh.

## The grammar

Write one `[env]` table. Give each key a comment block immediately above it: a
blank line between them, or another assignment, ends the block. That comment is
what the consumer reads beside the key in their own settings file. Every value
is a single-line double-quoted string containing no `"` and no `\`.

`kendex marketplace check` reads the template strictly and names each defect
with the line it sits on: a file that is not valid TOML, an assignment outside
`[env]`, a second `[env]` header, a key with no comment block above it, a value
in any other shape, and a key assigned twice. The check runs strict, so any of
them fails it.

Seeding stays lenient, and that is the point of checking: in the consumer's
`kendex.settings.toml` a duplicate assignment inside `[env]` fails the load,
while a template with one seeds its first declaration and drops the rest
without a word. Write each key once.

## Naming

Prefix keys with the skill name in upper-snake — `REVIEW_GATE_MODE` for a
skill named `review-gate`. This is a convention and nothing enforces it: a
skill that deliberately ships a companion package's key is legitimate.

## Where a value comes from

Scripts read the `[env]` table, ignoring assignments outside it, with one
precedence, highest first:

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
assignment in the template. Name it in your `SKILL.md` instead, as "set `X` in
`.env.local`", where the marketplace page shows it.
