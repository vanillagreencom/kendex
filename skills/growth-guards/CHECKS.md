# growth-guards checks

What each check fails, its scopes and flags, the keys it reads, and the grammar a test pins. Invocation and hooks: [README.md](README.md); every key with its default: [SKILL.md](SKILL.md).

Every check exits `0` clean, `1` violations, `2` usage, config or collection error. Scans read index content, and content decides what is read: an attributes rule cannot hide a path, and a symlink, a submodule gitlink, or a blob with a NUL in its leading bytes at a scanned path is named as unmeasured, never folded into a clean count. Excludes lists and baselines take the formats in `SKILL.md § Configuration`. A path-glob list replaces the default; an empty list is a config error; a list matching no tracked file is a clean pass.

## todo-ban

`TODO`, `FIXME`, `HACK`, `XXX` in a marker shape fail, case-sensitively, with no baseline:

- the word at line start, after whitespace, or after a comment leader, immediately followed by `:` or `(`;
- the bare word directly after a comment leader (only whitespace between), followed by whitespace or end of line.

Comment leaders: `//`, `#`, `;`, `/*`, `<!--`. A marker immediately preceded by a backtick, a quote, or joined text matches neither shape; a space between exempts nothing.

`--staged` judges only the lines the staged diff adds, renames held to exact content (a pure move adds no line; a file that moved and changed is read whole); a first commit is judged like any other. The default judges every tracked file. `--excludes FILE` overrides `GROWTH_GUARDS_TODO_EXCLUDES`.

## byte-ceiling

A tracked file a change puts over `GROWTH_GUARDS_BYTE_CEILING_KB` (KB = 1024 bytes) fails; size is the blob's object size. Exempt by exact basename: `Cargo.lock`, `package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock`, `bun.lockb`, `flake.lock`, `poetry.lock`, `uv.lock`, `Pipfile.lock`, `Gemfile.lock`, `composer.lock`, `go.sum`, `gradle.lockfile`, `packages.lock.json`, `Package.resolved`. Asset trees go in `GROWTH_GUARDS_BYTE_EXCLUDES`, overridden by `--excludes FILE`.

- `--staged` (default): files added, modified or type-changed in the staged diff, renames held to exact content.
- `--base REF`: files added since the merge-base with REF.
- `--all`: every tracked file.

A copy is an addition; symlinks and gitlinks are not sized.

## suppression-ban

Blanket suppressions fail flat, scanned by pathspec:

| Language | Pathspec | Banned shape |
|---|---|---|
| Rust | `*.rs` | `#![allow(...)]` inner attribute at line start |
| Python | `*.py` | own-line `# ruff: noqa` or `# flake8: noqa`, with or without codes |
| JS/TS | `*.js *.jsx *.ts *.tsx *.mjs *.cjs *.mts *.cts *.vue *.svelte` | bare block `/* eslint-disable */` |
| Go | `*.go` | `//nolint` alone, or `//nolint:all` |
| Biome | the JS/TS pathspec plus `*.css *.jsonc` | `biome-ignore-all`; `biome-ignore-start` with no rule or a bare `lint` or `lint/<group>` scope; `biome-ignore lint:` or `biome-ignore lint/<group>:` naming no rule |

Legal: a per-line suppression naming its lint with a reason (`# noqa: E501`, `// eslint-disable-next-line rule -- why`, `//nolint:gosec // why`, `// biome-ignore lint/<group>/<rule>: why`, a per-item Rust attribute).

The bare-allow ratchet counts reasonless `#[allow(dead_code)]` and `#[allow(unused...)]` attributes per `*.rs` file; `reason = "..."` exempts one. Counts are held to `GROWTH_GUARDS_SUPPRESSION_BASELINE`, tighten-only: a new bare allow, growth past a row, and a row looser than reality all fail. `--update` lowers or removes rows and re-checks, never adds or raises one; the first baseline is written by hand from the reported `new bare allow` lines. `--baseline FILE` and `--excludes FILE` override the baseline and `GROWTH_GUARDS_SUPPRESSION_EXCLUDES`.

## conflict-markers

Seven `<`, seven `|`, or seven `>` at column 0, followed by a space or end of line, fail in every tracked file. Indented or quoted occurrences and the seven-`=` separator do not fire. `--excludes FILE` overrides `GROWTH_GUARDS_CONFLICT_EXCLUDES`.

## changelog-entries

One judge over two scopes: the fragments a branch writes and the record a release folds them into. A path in both scopes is a config error. Text that is not valid UTF-8 is a collection error naming the line.

### Fragments

Every tracked path `GROWTH_GUARDS_CHANGELOG_PATHS` matches must be:

- a real text file (a symlink, gitlink or binary blob is refused);
- placed by a pattern: a pattern is `<root...>/<section>/<name>`, its last two segments say where the section sits and its depth which paths it places, and the section directory is one of `added`, `changed`, `deprecated`, `removed`, `fixed`, `security`. `changelog.d/*/*.md` matches a deeper path but places only one at its own depth;
- exactly one Markdown list item: the first non-blank line opens with a hyphen and a space and says something, and every later non-blank line indents under it;
- within `GROWTH_GUARDS_CHANGELOG_CAP` characters.

A pattern's root is its leading run of glob-free directories (`changelog.d/*/*.md` roots at `changelog.d`); a glob-free pattern names one file and roots nowhere. Every tracked path under a root that no pattern matches is a violation, except a `README.md` directly under a root and the configured record. No matching file is a clean pass; switch the check off by dropping it from `GROWTH_GUARDS_CHECKS`.

`--collate` judges, then on a clean verdict folds each fragment into the record's `[Unreleased]` section under its section's heading, in Keep a Changelog order and filename order within a section, and deletes the fragment files and each section directory left empty. It refuses, writing nothing, when the index and the working tree disagree about a judged path; the record is replaced whole. The release commit is its only caller.

### The record

`GROWTH_GUARDS_CHANGELOG_RECORD` is the collated file; empty switches this scope off. A line the index carries under `## [Unreleased]` that HEAD does not is a violation.

The heading is found by structure: a fence opens on three or more backticks or tildes and closes only on a run at least as long of the same character alone on its line; nothing inside a fence is a heading; a level-1 or level-2 ATX heading switches the section on or off; the text matches on equality, case-folded, after its leading spaces and hashes.

- Exit 2: an unterminated fence; a second `## [Unreleased]` heading.
- Violations: the heading staged away where HEAD carries one; no `## [Unreleased]` heading; a level-3 heading inside the section naming no Keep a Changelog section; a record tracked in HEAD and absent from the index (retire the scope by emptying the key).
- A record HEAD carries that this guard would not accept skips the comparison, naming the reason; shape rules judge the staged copy.

The comparison runs only where HEAD already carries the record. `GROWTH_GUARDS_CHANGELOG_COLLATE=1` in the environment declares the collator's own write and bypasses that comparison and nothing else. Each stand-down names itself in the verdict.

### Measuring one entry

Lines joined with CR stripped, whitespace runs collapsed to one space, trimmed, counted in characters (one per UTF-8 sequence). A long entry is named with its file, length and first line, C0 controls except tab, and DEL, replaced.

## prose

A history reference in a scanned markdown file fails: a calendar date (`20YY-MM-DD`), a three- or four-digit issue number after `#`, or one of `previously`, `used to`, `no longer`, `reverted`, `an earlier`, `earlier round`, `incident`, `historically`, `originally`, `at the time`. Matching is case-insensitive and whole-word (`incidental`, `unreverted` do not fire). The issue-number shape takes no leading boundary (`<file>.md#1204` fires), and the character after the digits must be neither a digit nor a hex letter (`#12345`, `#1234ab`, `#0088cc` pass). A decision ID (`D042`) carries no `#` and never fires.

Scope is `GROWTH_GUARDS_PROSE_PATHS`; there is no excludes list. The default, each name spelled twice because `*` crosses `/` but never stands in for the separator:

```
SKILL.md */SKILL.md AGENTS.md */AGENTS.md CLAUDE.md */CLAUDE.md workflows/*.md */workflows/*.md agents/*.md */agents/*.md docs/architecture/*.md
```

The `no tracked file matches` verdict prints only when nothing was skipped.

## md-format

A scanned markdown file holds one paragraph per line and one list item per line, blank lines between paragraphs, list blocks, headings and fences, and no trailing-double-space break. `md-reflow` rewrites a file to the format.

The grammar is `scripts/lib/md-blocks.awk`'s, with the line-shape predicates in `scripts/lib/md-shapes.awk`; both lanes and the reflow read by that pair:

- Front matter (`---` on line 1 to the next `---` line) is skipped.
- A fence opens on three or more backticks or tildes (a backtick run whose info string holds a backtick opens nothing) and closes on a run of the same character at least as long, alone on its line; every line between is skipped. A fence opened inside a blockquote closes when the quote ends.
- An HTML block opens on a line whose first character is `<` followed by `!--`, `?`, `![CDATA[`, `!` and a letter, a block-level tag name (CommonMark's list plus `source`), or a complete tag alone on its line where no paragraph is open. The first four end on the line carrying `-->`, `?>`, `]]>` or `>`; the tag kinds end at the next blank line. Every line is skipped.
- A tag whose name holds `_` is a prompt section: alone on its line it opens a block to the line holding its closing tag, blank lines included, and one never closed is refused. An opener sharing its line with prose is a paragraph line; a lone closing tag is a one-line block.
- A line indented four or more columns past the innermost item's content indent (a tab counts to the next multiple of four), directly after a blank line, opens indented code; it and every following line indented as far are skipped.
- A line whose first non-blank character is `|` opens a table, as does a one-line paragraph holding `|` over a delimiter row (cells of `-` with an optional `:` at either end, separated by `|`, outer pipes optional, at least one pipe). The table runs to the next blank line; every line until then is a skipped row, except a heading, fence or thematic break, judged as itself. A table is a boundary.
- A heading is `#` to `######` followed by a space, a tab or end of line, or a `=` or `-` underline directly under a paragraph line. It needs a blank line before and after it whatever the neighbour, except a one-line HTML comment directly over it.
- A list item is `-`, `*`, `+`, `N.` or `N)` followed by a space (`* * *` and `- - -` are thematic breaks), on one line, at any indent. It needs a blank line before it unless the previous line is an item; a paragraph indented to the item's content after a blank line is a paragraph of the item.
- A definition, `[label]: destination` at line start, is a boundary; definitions stack. A `[label]:` whose destination sits on the next line is a paragraph line and its wrap.
- A thematic break (`---`, `***`, `___`, spaces allowed) is a boundary.
- A blockquote's `>` markers are stripped and its content judged by the same rules. A change of depth is a boundary, except a paragraph line at a lower depth directly under a quoted paragraph line, its lazy continuation; a heading or fence closer beside the change still needs its blank line.
- Anything else is a paragraph line.

Violations, each naming file, line and rule:

- a paragraph line directly under a paragraph or list item line;
- a heading, a fence or a list item directly under a paragraph or list line;
- a heading, or a fence closer, not followed by a blank line;
- a heading not preceded by a blank line, an HTML block line excepted;
- a paragraph or list line ending in two or more spaces;
- a CRLF line ending, after which the file is not judged.

An unterminated fence, front matter, HTML comment or prompt-section block is exit 2 naming the file and opening line.

`--staged` judges every markdown file the staged diff adds, modifies or type-changes, in full, from the index, renames held to exact content. `--all` judges every tracked file `GROWTH_GUARDS_MD_PATHS` names minus `GROWTH_GUARDS_MD_EXCLUDES`. With neither, `GROWTH_GUARDS_MD_SCOPE` decides: `touched` is `--staged`, judging nothing when nothing is staged; `all` is `--all`. The commit batch hands the lane `--staged`.

### md-reflow

`scripts/md-reflow [--check] PATH...`, or `--staged` or `--all` with md-format's selection, rewrites the work-tree copy: the lines of a paragraph, a list item and a blockquote paragraph join with single spaces, a trailing-double-space break joins away, and a missing blank line goes before a heading, fence or list that follows a paragraph line, on both sides of a heading, and after a fence closer. Skipped blocks and one-line definitions come out byte-identical, as does a clean file; a file with no trailing newline keeps none. A rewritten file passes md-format and a second rewrite changes nothing. `--check` writes nothing and exits 1 naming each file a rewrite would change. A CRLF file, a symlink and a file holding a NUL are refused at exit 2. A PATH is taken from the current directory and must lie inside the repository.

## md-refs

A dead reference in a scanned markdown file fails. Fenced code, indented code and front matter are never read. Three forms:

- A link or reference definition whose destination is relative (no scheme, no leading `/`, not `mailto:`) must name a tracked file or directory, resolved against the citing file's directory; `..` above the repository root is dead. With `#anchor`, the target must be markdown and the anchor one of its heading slugs or an explicit `<a id="...">` or `<a name="...">`; a bare `#anchor` resolves in the citing file. A definition is read only where the line begins with its `[label]:`.
- A code span holding `<path>.md § Heading` must name a tracked file with a heading equal to `Heading` case-insensitively after trimming; one holding `<path>.md#anchor` a tracked file with that slug or explicit anchor. The path resolves against the citing file's directory, then the repository root. A path alone in a code span is not judged.
- A decision ID, `DECISION_ID_PREFIX` plus at least `DECISION_ID_WIDTH` digits bounded by non-alphanumerics, must have a tracked file `DECISIONS_DIR/<ID>-*.md`; where that directory is not tracked, IDs are not judged and the verdict says so.

The slug is GitHub's: link syntax, code-span backticks and HTML tags reduce to their text; ASCII letters lower-case (a non-ASCII letter keeps its case); every character not a letter, digit, space, `-` or `_` is dropped; each space becomes a hyphen; a repeat takes the first free `-1`, `-2` suffix.

Scopes are md-format's over `GROWTH_GUARDS_MD_REFS_PATHS` minus `GROWTH_GUARDS_MD_EXCLUDES`, with the same `GROWTH_GUARDS_MD_SCOPE`. Targets resolve against the index whatever the scope, so a link into a file the commit deletes is dead; a tracked path holding a newline is no link target.

## comments

A history reference in the comment text of a scanned source file fails: an issue id matching `GH_ISSUE_PATTERN` (empty keeps `[A-Z]+-[0-9]+`), a three- or four-digit issue number after `#` with the trailing guard `prose` uses, a calendar date (`20YY-MM-DD`), or one of `previously`, `used to`, `no longer`, `reverted`, `an earlier`, `earlier round`, `incident`, `historically`, `originally`, `at the time`, `added`, `new`, `existing code`, `phase N`. Words and dates are matched case-insensitively and whole-word; the issue id is matched as written, lowered and uppered, so a pattern written in one case matches the id in any case and a mixed-case pattern matches only its own spelling. A quoted example or backticked span inside the comment still counts. String literals and code are never judged. Each hit is reported once per line and shape. The default key shape matches `UTF-8` and `SHA-256`; a repository with one tracker prefix sets `GH_ISSUE_PATTERN` to it. The pattern is a POSIX ERE read by awk and `git grep`; one neither can compile is exit 2.

Opt-in: name `comments` in `GROWTH_GUARDS_CHECKS`. Scopes are `todo-ban`'s: `--staged` judges only the lines the staged diff adds, comment state read from the whole staged blob; the default reads every tracked file `GROWTH_GUARDS_COMMENT_PATHS` names minus `GROWTH_GUARDS_COMMENT_EXCLUDES`, overridden by `--excludes FILE`. A matched path the table below gives no grammar is named as unmeasured.

Comment text is extracted per family, by extension or, for a path with none, by the interpreter its `#!` line names. The default path list is exactly these extensions, with `Makefile` and `Dockerfile` by basename at the root and below:

| Family | Extensions | Comments read | Strings tracked |
|---|---|---|---|
| C | `rs` `go` `c` `h` `cc` `cpp` `hpp` `java` `kt` `kts` `swift` `wgsl` `js` `mjs` `cjs` `jsx` `ts` `tsx` `scss` `less` | `//` `///` `//!` to end of line; `/* */` across lines | `"…"` and `'…'` with backslash escapes; a backtick template literal across lines (`go`, `js`, `ts` and their variants); Rust `r"…"`, `r#"…"#`, a string spanning lines, a char literal, and a lifetime quote that opens nothing |
| CSS | `css` | `/* */` only | `"…"` `'…'` |
| Hash | `sh` `bash` `zsh` `py` `rb` `toml` `yml` `yaml` `mk` `Makefile` `Dockerfile`; no extension with a `#!` naming an interpreter ending in `sh`, or python or ruby (`node`, `deno`, `bun` take the C family) | `#` at the start of a word (line start or after whitespace) to end of line; line 1 `#!` is not a comment | `"…"` with escapes; `'…'` without escapes in shell, TOML and YAML, with escapes in Python and Ruby; shell `$'…'` with escapes; a shell string across lines; Python and TOML triple quotes across lines; a shell heredoc body (`<<WORD`, `<<-WORD`; the word runs to a blank or one of `;|&<>`, its quotes stripped; `<<` inside `((…))` is a shift) up to its terminator line |
| Dash | `sql` `lua` | `--` to end of line; SQL `/* */` and Lua `--[[ ]]` across lines | `"…"` `'…'` with escapes |
| Markup | `html` `htm` `xml` `svg` `vue` `svelte` | `<!-- -->` across lines | none |

The scanner is a character walk, not a parser. Its limits, each pinned by a control in `tests/comments.test.sh`:

- A `//` inside a JavaScript regex literal, a `#` glued to a Python or TOML value (`x = 1#c`), and a `--` inside a Lua long string `[[…]]` are read by the rules above, not the language's.
- A JavaScript template literal is one string to its closing backtick; a nested template inside `${…}` is not tracked.
- A Rust nested block comment closes at the first `*/`; a Lua `--[==[` level is not tracked.
- A shell line opening two heredocs honours the first; a Ruby heredoc, a YAML block scalar (`key: |`) and a Makefile recipe's shell are read as code, so a `#` inside them is a comment.
- A Vue or Svelte file is judged for `<!-- -->` only; the `//` inside its script block is not read.
- A C or JavaScript string ends at its line (a trailing backslash continuation is not tracked); a Rust string does not.
- A file that ends inside a block comment, a heredoc body or a string spanning lines is exit 2 naming the file and the opener's line; a JavaScript regex literal holding an odd number of backticks or quotes leaves the file in that state.

## commit-msg

One message, from FILE or stdin (FILE absent or `-`). Every applicable rule reports before the verdict.

- Shape: the header (the first non-blank, non-comment line) matches `type(scope)!: subject`, scope and `!` optional. Types are `GROWTH_GUARDS_COMMIT_TYPES`; the scope class `[#A-Za-z0-9 _.,/-]+` passes `fix(ABC-123):` and `fix(#123):`.
- Length: at most `GROWTH_GUARDS_SUBJECT_MAX` characters, counted as the changelog cap counts.
- Changelog: where `GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS` names a glob a changed path matches, the commit must also add or modify a path under `GROWTH_GUARDS_CHANGELOG_PATHS` or carry `[no-changelog]` in the header. Evidence is a path that comes out of the commit with content it did not carry there before (a new blob, a changed blob, a type that became a regular file, a rename destination); deleting a fragment is not writing one. `GROWTH_GUARDS_CHANGELOG_RECORD` counts only under `GROWTH_GUARDS_CHANGELOG_COLLATE=1`.

Both lists are read from `--raw` with rename detection pinned, against the parent the commit will have: HEAD, or HEAD's parent for an amend. An amend is read off the argv of the nearest `git` ancestor in `/proc/<pid>/cmdline`, only when `GIT_INDEX_FILE` says git started this hook; where nothing is readable (every macOS host) the parent is HEAD. `--amend` counts only where no value-taking option could have consumed it (`--mess --amend`, `-am --amend`, `--status --amend` are not amends); `--no-amend` counts wherever it stands; a bare `--` stops the scan. A rebase `reword` and an `edit` stop are amends; an all-`pick` rebase and an autosquash fixup are not.

Git-generated headers (Merge, Revert, Reapply, `fixup!`, `squash!`, `amend!`) skip shape and length and keep the changelog rule.
