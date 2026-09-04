# Settings a skill declares

A skill ships a `kendex.settings.toml.example` at its root for the keys a consumer sets. The file declares those keys, which is what the app's Settings pane renders and what a save is checked against, and it is what a write into the consumer's `kendex.settings.toml` is made from. Start from [templates/kendex.settings.toml.example](templates/kendex.settings.toml.example); the rule below is the one statement of what reaches a consumer's file and when, and a template's header, a skill's README and its SKILL.md point here rather than restating it.

Declare what somebody might reasonably change. The app shows one row per declared key and refuses to save a key no template declares; declaring costs the consumer nothing. A key only a maintainer or a test touches is read the same way and set by hand in `kendex.settings.toml` or any layer above it. Every key belongs in the SKILL.md table either way; that table is the reference and the body a marketplace page shows.

## What an install writes, and what it leaves

Seeding is a skill's alone: the same file under an agent, hook, command or MCP server installs normally and seeds nothing. It runs at project scope for an enabled skill at least one harness there targets; a global install writes nothing. A rendering the pass refuses does not take the settings write with it.

Two things put a key in a consumer's `kendex.settings.toml`, and nothing else ever does:

- An arrival writes the keys the template marks `# required`, once. Arrival is the consumer's `kendex.toml` gaining the declaration, read expanded: a bundle arrives its members, a skill arrives the dependencies it pulls in. Only `add` gains a declaration, so every other pass writes nothing; a refresh leaves the file byte-identical and a key the consumer deleted stays deleted. A declaration written by hand has spent the arrival; removing and re-adding the skill is the way back.
- A save from the app writes the key it names, marked or not, inserting the assignment when there is none.

Mark a key `# required` only when the consumer has to decide it and no default could stand in; a key whose empty or shipped value already does something sensible is not one, however important. Everything else stays declared and unmarked, so no arrival writes it.

- The marker is the template's own word, cut off before the assignment is written; it goes after the value and nowhere else. On a comment line of its own it marks nothing, and both misplacements are check findings. A marked key nobody has answered is reported in every plan and audit until they set it, so a template that gains a marked key after release reaches an existing consumer as a note, never a write.
- A key already assigned anywhere in the consumer's file, inside `[env]` or not, is never seeded over and never rewritten. Whether it is answered is the readers' narrower question: an assignment under another table, one spelled quoted or dotted, one written twice, or one holding a value the loaders refuse is reported as unanswered, naming the line that took the name.
- Where several packages ship the same key with the same default, nothing is said. Where they disagree, every plan and audit carries one note naming each owner and default, and a pass that writes the key writes the first declaration in package-name order that the pass admits: on an arrival, the first arriving package that marks it `# required`; on a save, the first in package-name order.
- Nothing revisits a block already in the consumer's file. Once a key and its comment land they are the consumer's, and a revised template does not follow them in; the comment you ship is the wording every consumer who takes the key keeps.
- An entry is written whole or not at all: a value the template never closes is refused by name and the plan says so, and a value spanning lines is never marked, never arrives, and refuses a save.

The seeding rules are `crates/core/src/settings_seed.rs`.

## The grammar

The shell loaders decide it (`skills/*/scripts/lib/kendex-env.sh` and `settings.sh` read the keys where they land), so what those refuse is what the check refuses:

- One `[env]` table, its header a lone `[env]` on its own line.
- A key is a shell identifier: letters, digits and underscores, starting with a letter or underscore.
- A value is one double-quoted string on one line, containing no `"` and no `\`; the only thing that may follow it is `# required`.
- Each key has a comment block immediately above it, ended by a blank line or another assignment; that comment is what the consumer reads beside the key.

`kendex marketplace check` reads a template against that grammar and names each defect with its line, including a template with no `[env]` table, a key with no comment block, an assignment outside `[env]`, a key assigned twice, and a file that is not valid TOML; the check runs strict, so any of them fails it. One run names every defect except that a TOML syntax error stops the parser at its first. Seeding itself stays lenient, so write each key once: a duplicate inside `[env]` fails the consumer's load while the template is read past.

## Naming

Prefix keys with the skill name in upper-snake: `REVIEW_GATE_MODE` for a skill named `review-gate`. A convention, not enforced; a skill that deliberately ships a companion package's key is legitimate.

## Where a value comes from

Scripts read the `[env]` table, ignoring assignments outside it, with one precedence, highest first: the process environment, `.env.local`, `.kendex/settings.toml`, `kendex.settings.toml`, the built-in default. A key may hold itself to a different policy as long as its own comment says so.

## Secrets are not settings

Ship only values that are safe to commit. A token, a credential or a personal identifier never appears as an assignment in the template; name it in the SKILL.md instead, as "set `X` in `.env.local`", where the marketplace page shows it.
