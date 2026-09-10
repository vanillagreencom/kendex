# Settings a skill declares

A skill ships a `kendex.settings.toml.example` at its root. It declares two kinds of key: the settings a consumer sets, under `[env]`, and the credentials the skill reads, under `[secrets]`. Both are what the app's Customize tab renders and what a save is checked against; only `[env]` is written into the consumer's `kendex.settings.toml`. Start from [templates/kendex.settings.toml.example](templates/kendex.settings.toml.example); the rule below is the one statement of what reaches a consumer's file and when, and a template's header, a skill's README and its SKILL.md point here rather than restating it.

Declare what somebody might reasonably change. The app shows one row per declared key and refuses to save a key no template declares; declaring costs the consumer nothing. A key only a maintainer or a test touches is read the same way and set by hand in `kendex.settings.toml` or any layer above it. Every key belongs in the SKILL.md table either way; that table is the reference and the body a marketplace page shows.

A skill may declare credentials and no settings. A template with a `[secrets]` table and no `[env]` table is complete.

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

- One `[env]` table and one `[secrets]` table, at most, each header a lone `[name]` on its own line. A template declares no other table.
- A key is a shell identifier: letters, digits and underscores, starting with a letter or underscore.
- A value is one double-quoted string on one line, containing no `"` and no `\`; the only thing that may follow it is `# required`. A `[secrets]` value is the empty string.
- Each key has a comment block immediately above it, ended by a blank line or another assignment; that comment is what the consumer reads beside the key.

`kendex marketplace check` reads a template against that grammar and names each defect with its line, including a template declaring neither table, a key with no comment block, an assignment outside both tables, a key assigned twice, a `[secrets]` key carrying a value, and a file that is not valid TOML; the check runs strict, so any of them fails it. One run names every defect except that a TOML syntax error stops the parser at its first. Seeding itself stays lenient, so write each key once: a duplicate inside `[env]` fails the consumer's load while the template is read past.

## Naming

Prefix keys with the skill name in upper-snake: `REVIEW_GATE_MODE` for a skill named `review-gate`. A convention, not enforced; a skill that deliberately ships a companion package's key is legitimate.

## Where a value comes from

Scripts read the `[env]` table, ignoring assignments outside it, with one precedence, highest first: the process environment, the project's private env file, `.kendex/settings.toml`, `kendex.settings.toml`, the built-in default. The private env file is `.env.local` unless `KENDEX_ENV_FILE` names another path inside the project; a path that could reach outside it fails the load. Inside is decided by resolving the directory the file sits in, not by reading the name: a name with no `..` in it still reaches out through a directory that is a link, and that fails the load too. A link at the private file itself is the project's own layout and loads — a git worktree links `.env.local` back to its main checkout so every worktree shares one credential file. That key is read from the same layers in the same order as every other setting, so `.kendex/settings.toml` outranks `kendex.settings.toml` and the process environment outranks both. The app writes the root file, so it honours a file the higher layer names and refuses to record a different one over it. A key may hold itself to a different policy as long as its own comment says so.

## Secrets

A credential is declared, never shipped. `[env]` carries values that are safe to commit; a token, a credential or a personal identifier goes under `[secrets]`:

```toml
[secrets]

# What the key lets this skill do, and where a consumer gets one. The app
# shows these lines beside the field.
MY_SKILL_TOKEN = "" # required
```

A `[secrets]` declaration is a key name, the comment block above it, and `# required` where the skill refuses to run without the key. Its value is the empty string and nothing else: a value there is a check finding, so no template can ship a credential, a placeholder or a default.

The consumer sets one in the app's Customize tab. kendex writes it to the project's private env file — `.env.local`, or the file `KENDEX_ENV_FILE` names — after confirming the file is not one kendex writes itself — `kendex.settings.toml`, `.kendex/settings.toml` and `.kendex-generated.json` are refused as destinations whatever git says about them — and that git does not track it and does ignore it, adding the ignore entry first where one is owed. Nothing under `[secrets]` is ever seeded into `kendex.settings.toml`, and no value reaches a plan, a diff, an error or a commit offer.

Declare a key under one table. A key declared under both, in one template or across two installed skills, has no destination anything can choose: the app offers no field for it and both write routes refuse it.

The precedence a consumer sees is `settings.md`'s own: the process environment first, then the private env file, then the settings files. `skills/*/scripts/lib/kendex-env.sh` reads them in that order, and `KENDEX_ENV_FILE` chooses which private file it reads.
