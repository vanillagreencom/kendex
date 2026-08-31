# Settings a skill declares

A skill ships a `kendex.settings.toml.example` at its root for the keys a
consumer sets. The file does two jobs. It DECLARES those keys, which is what
the app's Settings pane renders and what a save is checked against. And it is
what a write into the consumer's `kendex.settings.toml` is made from.

**What reaches a consumer's file, and when, is settled in [What an install
writes](#what-an-install-writes-and-what-it-leaves)** — that section and
nothing else, here or in the catalogue. A template's header, a skill's
`README.md` and a skill's `SKILL.md` say what is true of that skill's own
keys and point back here, so this is the one section to change if the rule
ever does.

Declaring a key is what puts it in front of a person. The app shows one row
per declared key and refuses to save a key no template declares, and declaring
alone costs a consumer nothing. So declare what somebody might reasonably
change, and leave out what only a maintainer or a test ever touches, such as a
scan's exclusion-file path or a cap nobody tunes. An undeclared key is read
the same way and is set by hand, in
`kendex.settings.toml` or any layer above it. Every key belongs in the
`SKILL.md` table either way; that is the reference, and it is the body a
marketplace page shows for a skill. A `README.md` beside it ships with the skill and appears in
the page's file list, but it is not what the page renders. For the other kinds
the rendered body is the package's one file: the agent's or command's markdown
after its frontmatter, and a hook script or MCP config whole, comments
included.

Start from
[`templates/kendex.settings.toml.example`](templates/kendex.settings.toml.example).

## What an install writes, and what it leaves

Seeding is a skill's alone. An agent, hook, command or MCP server that ships
one of these files installs normally and seeds nothing — the file is inert,
and no error says so. It runs on project scope, for an enabled skill at least
one harness here targets; a global install writes nothing. A rendering the
same pass refuses does not take the settings write with it: what a template
says is read whether or not that skill's tree lands.

Two things put a key in a consumer's `kendex.settings.toml`, and nothing else
ever does.

An ARRIVAL writes the keys the template marks `# required`, once. Arrival is
the consumer's `kendex.toml` gaining the declaration, read expanded — a bundle
arrives the members it carries, and a skill arrives the dependencies it pulls
in. Only `add` gains a declaration, so every other pass writes nothing: a
refresh leaves the file byte-identical, and a key the consumer deleted stays
deleted, in a fresh clone as much as anywhere. However the manifest gains the
declaration counts, so a consumer who hand-writes one has already spent the
arrival; a later `add` of that skill gains nothing and writes nothing, and
removing it and adding it again is the way back.

A SAVE from the app writes the key it names, marked or not, inserting the
assignment first so the value has somewhere to land. That is how most keys
reach a consumer's file, since only marked ones arrive.

Mark a key `# required` when the consumer has to decide it — when there is no
answer a default could stand in for. `LINEAR_TEAM` is one: empty, every Linear
write refuses rather than guess a team. A key whose empty or shipped value
already does something sensible is not one, however important it is; its
comment says what that value does, and a consumer who wants another writes it
themselves.

Everything else stays declared and unmarked, so no arrival writes it. A key
holding the value your own code reads when nothing assigns it buys the
consumer nothing and costs them a line in a tracked file; the consumer who
wants it puts it there.

The marker is the template's own word. It is cut off before the assignment is
written, so a consumer's file never carries it. Write it after the value and
nowhere else. On a comment line of its own it marks nothing, and both ways of
getting it wrong are findings: after a value, whatever you wrote there; on a
line of its own, the word however you capitalise it and inside whatever is
not a letter or a digit, so a bracket, a quote, an ellipsis or an invisible
character around it changes nothing. Only the ends of the line are read that
way, so a comment that merely mentions the word is an ordinary comment. A
marker nothing reads is silent twice over. No arrival writes the key, and
nothing reports it as unanswered either, because nothing downstream knows it
was ever marked.

A marked key nobody has answered is reported instead. So a template that gains
a marked key after release does not reach an existing consumer as a write into
their file; every plan and audit names the key until they set it.

A key already assigned in the consumer's file is never seeded over, and no
install rewrites a value. The presence check is deliberately wider than what
the readers look at: an assignment of that key anywhere in the file, inside
`[env]` or not, counts as present and suppresses the insert.

It suppresses the insert and nothing else. Whether a marked key is ANSWERED is
the readers' own narrower question, so an assignment under another table, one
spelled quoted or dotted, one written twice, or one holding a value the loaders
refuse is still reported as unanswered — nothing writes the key, because the
name is taken, and nothing reads it either, so the note names the line that
took the name rather than claiming the file assigns nothing.

Several packages may ship the same key. Where they agree on the default,
nothing is said. Where they disagree, every plan and audit carries one note
naming each owner and each default, and where the pass writes the key at all
it writes the first declaration, in package-name order, that the pass ADMITS.
On an arrival that is the first arriving package to mark the key `# required`:
a package shipping the key unmarked declares nothing this pass may write, so
it does not take the key by sorting first. A save admits every declaration of
the key it names, so there the first in package-name order is what lands.

Nothing ever revisits a block already in the consumer's file. Once a key and
its comment are there, whichever of the two put them there, they are the
consumer's: a revised template does not follow the revision in, because that
would be a write on a pass nobody asked for. So the comment you ship is the
wording every consumer who takes that key keeps, and revising it reaches
nobody who already has it.

## The grammar

The shell loaders decide this, not the template:
`skills/*/scripts/lib/kendex-env.sh` and `settings.sh` are what read your keys
where they land, so what those refuse is what this refuses.

- One `[env]` table. A table header is a lone `[name]` on its own line —
  `[env] # the table` is refused, and so is anything else with a bracket in it.
- A key is a shell identifier: letters, digits and underscores, starting with a
  letter or underscore. Anything else, `FOO-BAR` and `"WAIT"` included, is a
  key nothing reads, wherever it lands.
- A value is one double-quoted string on one line, containing no `"` and no
  `\`. The only thing that may follow it is `# required`.
- Each key gets a comment block immediately above it. A blank line between
  them, or another assignment, ends the block. That comment is what the
  consumer reads beside the key in their own settings file.

`kendex marketplace check` reads your template against exactly that grammar and
names each defect with the line it sits on; it also names a template with no
`[env]` table at all, a key with no comment block, an assignment outside
`[env]`, a key assigned twice, and a file that is not valid TOML. The check
runs strict, so any of them fails it.

One run names every defect the check itself finds, including a key that is
wrong in more than one way. A TOML syntax error is reported alongside them,
but the parser stops at its first, so a file with two of those takes two
runs.

Seeding stays lenient, and that is the point of checking: in the consumer's
`kendex.settings.toml` a duplicate assignment inside `[env]` fails the load,
while a template with one is read past without a word. On a pass that writes
the key at all, which the rule above settles and nothing here widens, the
first declaration seeding can write whole is what lands and the rest are
dropped. Write each key once.

A value the template never closes is the one thing seeding will not pass
over in silence. It writes nothing for that key — a partial value would stop
the consumer's file parsing from that line down — and the plan names the key
instead.

A value that takes more than one line reaches nobody either way. The marker
can only follow a value that closes on its line, so a multiline value is
never marked and no arrival writes it, and a save naming that key refuses
because the loaders read no value out of that shape. The check refuses the
shape outright, so this is what a template that ships one anyway gets.

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
