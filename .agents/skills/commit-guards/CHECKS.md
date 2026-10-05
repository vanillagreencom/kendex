# commit-guards checks

What each check fails, its scopes and flags, the keys it reads, and the grammar a test pins. Invocation and hooks: [README.md](README.md); every key with its default: [SKILL.md](SKILL.md).

Every check exits `0` clean, `1` violations, `2` usage, config or collection error. Scans read index content, and content decides what is read: an attributes rule cannot hide a path, and a symlink, a submodule gitlink, or a blob with a NUL in its leading bytes at a scanned path is counted as unmeasured, never folded into a clean count. The verdict line carries that count and names no path, so a tree tracking hundreds of symlinks does not bury the lane that failed; md-refs alone names a path: the one a judged reference lands on, or every one under its `--verbose`. Excludes lists and baselines take the formats in `SKILL.md § Configuration`. A path-glob list replaces the default; an empty list is a config error; a list matching no tracked file is a clean pass.

## todo-ban

`TODO`, `FIXME`, `HACK`, `XXX` in a marker shape fail, case-sensitively, with no baseline:

- the word at line start, after whitespace, or after a comment leader, immediately followed by `:` or `(`;
- the bare word directly after a comment leader (only whitespace between), followed by whitespace or end of line.

Comment leaders: `//`, `#`, `;`, `/*`, `<!--`. A marker immediately preceded by a backtick, a quote, or joined text matches neither shape; a space between exempts nothing.

`--staged` judges only the lines the staged diff adds, renames held to exact content (a pure move adds no line; a file that moved and changed is read whole); a first commit is judged like any other. The default judges every tracked file. `--excludes FILE` overrides `COMMIT_GUARDS_TODO_EXCLUDES`.

## byte-ceiling

A tracked binary or non-text file a change puts over `COMMIT_GUARDS_BYTE_CEILING_KB` (KB = 1024 bytes) fails; size is the blob's object size. An existing file already over the ceiling may stay the same size or shrink, but may not grow. Exempt by exact basename: `Cargo.lock`, `package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock`, `bun.lockb`, `flake.lock`, `poetry.lock`, `uv.lock`, `Pipfile.lock`, `Gemfile.lock`, `composer.lock`, `go.sum`, `gradle.lockfile`, `packages.lock.json`, `Package.resolved`, `.kendex-lock.json`. Asset trees go in `COMMIT_GUARDS_BYTE_EXCLUDES`, overridden by `--excludes FILE`.

Text and source files have no ceiling. The shared Git binary classifier checks content rather than names or attributes.

A binary file not over the ceiling but at or above `COMMIT_GUARDS_BYTE_WARN_PCT` percent of it prints `near-ceiling` naming the path, its bytes, the ceiling in bytes and the percent reached, and does not fail. The percent must be 1-100; above 100 the threshold would sit past the ceiling and switch the notice off silently, so it is a configuration error like any other.

- `--staged` (default): files added, modified or type-changed in the staged diff, renames held to exact content.
- `--base REF`: files added, modified or type-changed since the merge-base with REF — three dots, so the baseline is the blob REF and HEAD share.
- `--against REF`: the same files between REF's own tree and HEAD — two dots, so the baseline is REF's own blob. Where REF is an ancestor of HEAD the two scopes agree. Where they have diverged they do not, and only this one measures what landing HEAD at REF would do to REF: a file over the ceiling at the shared ancestor, smaller at REF and larger at HEAD, is a shrink to `--base` and growth to `--against`.
- `--all`: every tracked file. A sweep has no source blob, so an oversized file's prior is its row in `COMMIT_GUARDS_BYTE_BASELINE` (`path<TAB>bytes`, read from the index), overridden by `--baseline FILE`. A file at its row passes, one past its row fails as growth, and one with no row fails as oversized. Rows naming text files are ignored. Every other row larger than its file fails `baseline-loose`, and every other row naming no oversized binary file the sweep judges fails `baseline-stale`, so the binary baseline only tightens.

The batch names the scope: `commit-guards all` hands the lane `--all`, `all --base REF` hands `--base REF`, `all --against REF` hands `--against REF`, `all --staged` hands `--staged`. byte-ceiling takes a range under every setting, since it is ratcheted and the range is the question it answers. The two range scopes also reach md-format and md-refs, on the same dot conventions, but only where `COMMIT_GUARDS_MD_SCOPE` is `touched`; under `all` those lanes are handed `--all` instead, because a range is narrower than the sweep that setting asks for. A copy is an addition; symlinks and gitlinks are not sized.

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

The bare-allow ratchet counts reasonless `#[allow(dead_code)]` and `#[allow(unused...)]` attributes per `*.rs` file; `reason = "..."` exempts one. Counts are held to `COMMIT_GUARDS_SUPPRESSION_BASELINE`, tighten-only: a new bare allow, growth past a row, and a row looser than reality all fail. `--update` lowers or removes rows and re-checks, never adds or raises one; the first baseline is written by hand from the reported `new bare allow` lines. `--baseline FILE` and `--excludes FILE` override the baseline and `COMMIT_GUARDS_SUPPRESSION_EXCLUDES`.

Generated paths and adopted source follow [SKILL.md § Generated-file exclusions](SKILL.md#generated-file-exclusions).

## conflict-markers

Seven `<`, seven `|`, or seven `>` at column 0, followed by a space or end of line, fail in every tracked file. Indented or quoted occurrences and the seven-`=` separator do not fire. `--excludes FILE` overrides `COMMIT_GUARDS_CONFLICT_EXCLUDES`.

## changelog-entries

Ordinary runs check fragments, configured version bumps and package versions. `--collate` also validates the destination record before writing. A path in both roles is a config error. Text that is not valid UTF-8 is a collection error naming the line.

### Fragments

Every tracked path `COMMIT_GUARDS_CHANGELOG_PATHS` matches must be:

- a real text file (a symlink, gitlink or binary blob is refused);
- placed by a pattern: a pattern is `<root...>/<section>/<name>`, its last two segments say where the section sits and its depth which paths it places, and the section directory is one of `added`, `changed`, `deprecated`, `removed`, `fixed`, `security`. `changelog.d/*/*.md` matches a deeper path but places only one at its own depth;
- exactly one Markdown list item: the first non-blank line opens with a hyphen and a space and says something, and every later non-blank line indents under it. Fragments have no length limit.

A pattern's root is its leading run of glob-free directories (`changelog.d/*/*.md` roots at `changelog.d`); a glob-free pattern names one file and roots nowhere. While `COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS` declares packages, a pattern whose segment after its root is a bare `*`, followed by the section and the name alone, has a package slot: `changelog.d/*/*/*.md` places `changelog.d/<package>/<section>/<name>`, that package's entry. A package entry must name a [declared package](#version-bumps), or fails with `fragment-package=<root>/<package>`. Every other fragment, one a pattern globbing deeper in its path places included, is the repository's own program entry. Every tracked path under a root that no pattern matches is a violation, except a `README.md` directly under a root and the configured record. No matching file is a clean pass; switch the check off by dropping it from `COMMIT_GUARDS_CHECKS`.

`--collate` judges, then on a clean verdict folds each program fragment into the record's `[Unreleased]` section under its section's heading, in Keep a Changelog order and filename order within a section. Package fragments fold under the section's `### Packages` heading, after any blocks already there: one `#### <package> <version>` heading per package, its version the one its [package file](#version-bumps) states, or `#### <package>` for a versionless package, then its entries in section order. The fold deletes the fragment files and each section and package directory left empty. It requires `COMMIT_GUARDS_CHANGELOG_COLLATE=1` and refuses, writing nothing, when the index or working tree has staged, unstaged or non-ignored untracked changes. The record is replaced whole. The release commit is its only caller.

### The record

`COMMIT_GUARDS_CHANGELOG_RECORD` names the collation destination. Ordinary checks permit edits to its wording and headings. A configured version bump reads the record only for its release's entries.

- `--collate` with accepted fragments requires a tracked, regular text destination with one `## [Unreleased]` section. Section headings use the Keep a Changelog names or `Packages`, so each fragment has a destination.
- Missing or duplicate pending sections, unclosed fences, and unknown section names refuse collation before any write.
- `COMMIT_GUARDS_CHANGELOG_COLLATE=1` authorizes `--collate` and lets `commit-msg` count a record change as the release changelog entry. It does not change fragment validation.

### Release versions

A repository that releases chooses each version by this rule. Where `COMMIT_GUARDS_CHANGELOG_VERSION_PATHS` or `COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS` is set, the [version-bump check](#version-bumps) refuses the increases it lists, and judges a minor or a patch only from 1.0.

- The program's version reads the program's entries alone. A package's entry, a package fragment or an item under the record's `### Packages`, proposes no program version, whatever its section or Breaking mark.
- A package versions on its own: each commit that changes it raises its version by this rule against that commit's own package entries.

- From 1.0, fixes, internal changes, refactors, tests and docs are a patch. A minor needs a new user-facing capability or a consumer-visible setting. A breaking change is a major and needs the owner's approval.
- Before 1.0, a minor marks a break and a patch holds everything else.
- An `added/` fragment names only something a consumer of the repository uses. Internal tooling and tests go under `changed/`, or carry no fragment where [commit-msg](#commit-msg) owes none.
- A critical fix (broken install, data loss, security, a blocked consumer) ships promptly and is never held for a batch.
- When several critical fixes are open or in flight, they land together in one release, not one release each.
- Otherwise, cut at most one release a day, batching what has merged.

### Version bumps

- `COMMIT_GUARDS_CHANGELOG_VERSION_PATHS` selects tracked JSON files by space-separated path globs. Empty, the default, disables version checks. A selected changed file must be regular JSON with a string `version` in `major.minor.patch` form, with optional prerelease and build suffixes. jq reads both versions. Missing jq or unreadable versions are collection errors.
- The default and `--staged` compare the commit's parent to the index: HEAD, or HEAD's parent in an amend, read as [commit-msg](#commit-msg) reads it, so HEAD where the committing argv is unreadable. `--base REF` compares HEAD's merge base with REF to the index. `--against REF` compares REF itself to the index. The batch passes its range to this lane, or `--against` the ref a `--history REF` caller names; the pre-push hook names the newer of HEAD's merge bases with the remote head and with the remote's default branch. Fragment validation always reads the whole index. A newly added version file has no prior version to increase.
- jq compares the `major.minor.patch` numbers with the suffixes removed, so the bump is the first number that increased; a suffix change alone, or a decrease, is no bump.
- An increased major fails with `major-breaking=PATH:OLD:NEW` unless its release has a list item starting `- **Breaking:**` followed by non-blank text. The check cannot judge whether the text describes the actual break or gives a sufficient migration note.
- From 1.0, a prior major of 1 or more, a minor increase fails with `minor-breaking=PATH:OLD:NEW` when its release holds a `- **Breaking:**` item. A patch increase fails with `patch-added=PATH:OLD:NEW` when its release holds an Added entry and with `patch-breaking=PATH:OLD:NEW` when it holds a Breaking one. An Added entry is an `added/` fragment or an item directly under the record's `### Added` heading. Each refusal's next record is `entry-preview=`, the first such entry's first line. Below 1.0 neither increase is judged.
- A `package.json` outside the directory of `COMMIT_GUARDS_CHANGELOG_RECORD`, or any `package.json` while the record is off, is a package and uses only its adjacent `CHANGELOG.md`: `### Unreleased` before release, or `### <new version>` as the first release section after the release renames that heading. Another package's call-out does not count. A package record has no Added section, so a package patch takes the Breaking refusal only.
- Other version files, a `package.json` beside the record included, use an accepted program fragment or the configured record's `## [Unreleased]` or the first release section, `## [<new version>] - <date>`, less its `### Packages` part. This permits the release commit after collation deletes fragments and the caller sets the version. Past versions and fenced examples do not count. An unreadable record fails closed.
- Under `--against`, once a record holds the new version's own section, that section alone is the release's entries, for a package record too. Pending fragments and the pending section wait for the next release, so a branch restacked past a release and judged against its pre-restack tip is not refused for that release's bump. The default, `--staged` and `--base` runs read the fragments and both record sections, and a major whose fragments hold a Breaking entry reads no record in any run.
- `COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS` declares packages by space-separated path globs; empty, the default, disables package entries and the package check. A selected `SKILL.md` names its directory and versions it: `skills/linear/SKILL.md` versions `skills/linear/` and reads `changelog.d/linear/`. Any other selected file names itself less its extension and carries no version: `hooks/command-safety.sh` declares `command-safety`. A glob selects a file at its own depth only, so `hooks/*.sh` leaves `hooks/tests/lib/assert.sh` undeclared. Two package files declaring one name are a collection error, `package-duplicate=FIRST:SECOND`, since a package fragment could resolve to either. A versioned package's version is its frontmatter `metadata.version`, plain, double-quoted or single-quoted, in the same form; a package file the check reads without one is a collection error.
- Each commit that changes a versioned package raises its version. A diff touching any path under its directory must raise it, or fails with `package-unbumped=PATH:OLD`; a newly added package file has no prior version to raise, and a package fragment alone touches no package directory. The raise is judged as above against the package fragments that same diff adds, never a fragment an earlier change added, whose release that was, even where this diff edits it. Every scope reads the diff the scope bullet above names.
- The compatibility policy belongs to the consuming repository's release standard, not this configurable catalog check.
- [`tests/changelog-entries.test.sh`](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/tests/changelog-entries.test.sh) pins each refusal against a passing control: a major with and without a named Breaking entry, a minor with a Breaking or an Added entry, a patch with an Added, Breaking, Changed or Fixed entry, a 0.x patch, a patch whose own release section leaves an added fragment pending under `--against` and refuses it otherwise, a patch refused under `--base` for a pending record Added entry beside its own release section, and a major whose own release section holds no Breaking entry beside a Breaking fragment, and a `package.json` judged as the app's version file beside a root or nested record and as a package with the record off. Its package rows pin a package-only Breaking entry that leaves a program minor alone beside a program one that refuses it, a package minor refused for its own Breaking entry and a patch for its own Added one, a 0.x package minor left unjudged, the unraised package change against a raised one, with and without version files configured, another package's, an earlier change's or an edited earlier entry ignored, a versionless hook's change and entry accepted, a misspelled package directory and a nested hook test helper's name refused as no package, an agent and a skill of one name refused as a duplicate, a new package, plain and single-quoted versions beside a top-level `version:` line, a mid-path-glob pattern placing program entries, a record `### Packages` Breaking entry beside the same entry under `### Changed`, an amend judged against HEAD's parent beside a next commit judged against HEAD, and copies of the script, one reading every fragment as the program's, one without the unraised refusal, one without the package lookup, one matching package globs across `/`, one without the duplicate refusal, one version-checking a versionless package and one diffing an amend against HEAD, that each turn their row red. [`tests/changelog-collate.test.sh`](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/tests/changelog-collate.test.sh) pins a skill's versioned heading beside a nested hook test helper of its name.

## prose

This audit runs only when selected through `COMMIT_GUARDS_CHECKS`. The default chain excludes it.

A calendar date (`20YY-MM-DD`) or a three- or four-digit issue number after `#` in a scanned markdown file fails. Ordinary words do not trigger this check. The issue-number shape takes no leading boundary (`<file>.md#1204` fires), and the character after the digits must be neither a digit nor a hex letter (`#12345`, `#1234ab`, `#0088cc` pass). A decision ID (`D042`) carries no `#` and never fires.

Scope is `COMMIT_GUARDS_PROSE_PATHS` minus `COMMIT_GUARDS_MD_EXCLUDES`, the exclusion list the markdown lanes read, so a vendored skill under a render tree is carved out with a reason rather than by narrowing the scan. An explicit path list is used as given. The default is the load-point files, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` and `SKILL.md` at any depth, each name spelled twice because `*` crosses `/` but never stands in for the separator:

```
SKILL.md */SKILL.md AGENTS.md */AGENTS.md CLAUDE.md */CLAUDE.md GEMINI.md */GEMINI.md
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

`--staged` judges every markdown file the staged diff adds, modifies or type-changes, in full, from the index, renames held to exact content. `--base REF` and `--against REF` judge the same over a commit range, byte-ceiling's dots: three for what the branch adds over the ancestor it and REF share, two for what the change would do to REF's own tree. `--all` judges every tracked file `COMMIT_GUARDS_MD_PATHS` names minus `COMMIT_GUARDS_MD_EXCLUDES`. With no flag, `COMMIT_GUARDS_MD_SCOPE` decides: `touched` is `--staged`, judging nothing when nothing is staged; `all` is `--all`. The commit batch hands the lane `--staged`. A range-scoped batch hands it the range only under `touched`; under `all` it hands `--all`, since a range would answer a narrower question than the scope the project configured. The push batch withholds the lane where it has no range and the scope is `touched`.

### md-reflow

`scripts/md-reflow [--check] PATH...`, or `--staged` or `--all` with md-format's selection, rewrites the work-tree copy: the lines of a paragraph, a list item and a blockquote paragraph join with single spaces, a trailing-double-space break joins away, and a missing blank line goes before a heading, fence or list that follows a paragraph line, on both sides of a heading, and after a fence closer. Skipped blocks and one-line definitions come out byte-identical, as does a clean file; a file with no trailing newline keeps none. A rewritten file passes md-format and a second rewrite changes nothing. `--check` writes nothing and exits 1 naming each file a rewrite would change. A CRLF file, a symlink and a file holding a NUL are refused at exit 2. A PATH is taken from the current directory and must lie inside the repository.

## md-refs

A dead reference in a scanned markdown file fails. A citing file at or below a path in the indexed `.kendex-lock.json` `emitted.paths` warns instead, with the citing file, target and `kendex report` command. A consumer-authored citing file still fails, including one citing a rendered target. `--strict` makes rendered-file references fail too; the catalog install-layout test uses it. An absent lock lists no paths; a scan that reads an unreadable or malformed lock exits 2. Fenced code, indented code and front matter are never read. Forms:

- A link or reference definition whose destination is relative (no scheme, no leading `/`, not `mailto:`) must name a tracked file or directory, resolved against the citing file's directory; `..` above the repository root is dead. With `#anchor`, the target must be markdown and the anchor one of its heading slugs or an explicit `<a id="...">` or `<a name="...">`; a bare `#anchor` resolves in the citing file. A definition is read only where the line begins with its `[label]:`.
- A code span holding `<path>.md § Heading` must name a tracked file with a heading equal to `Heading` case-insensitively after trimming; one holding `<path>.md#anchor` a tracked file with that slug or explicit anchor. The path resolves against the citing file's directory, then the repository root. A path alone in a code span is not judged.
- A code span holding `<path>::<phrase>` is a content citation, read where the text before the first `::` holds a `/` and is spelled from `A-Za-z0-9`, `.`, `_`, `-` and `/` alone, and the phrase after it is not empty. The path resolves as the citation above does and must name a tracked file; that file's bytes must hold the phrase, byte for byte, as a literal substring. This proves the cited file still carries the text the sentence quotes and nothing about what the text means: no test name is parsed and no framework is known. A path in a code span with no `::` phrase stays a name, because a bare path in prose is as often a default value, a file a skill writes at run time, or a path in another repository. A citation into binary content is exit 2. A `§` in the span wins, so `<path> § Heading` is never read as a content citation; the form is read in Markdown only, never in comment text or a TOML string.
- A relative markdown link followed by `§` must start with an existing heading name from that target. Matching ignores case, backticks, and emphasis markers. The heading name ends at a word boundary; prose can follow it. A section number also resolves to a heading with that number. Text routes check a heading prefix. Use an anchor link or an exact code-span citation where heading names share a prefix.
- A decision ID, `DECISION_ID_PREFIX` plus at least `DECISION_ID_WIDTH` digits bounded by non-alphanumerics, must have a tracked file `DECISIONS_DIR/<ID>-*.md`; where that directory is not tracked, IDs are not judged and the verdict says so. IDs inside a complete inline link with a non-local destination (a scheme or leading `/`) are excluded, in both its label and destination. Bare IDs, IDs in relative links and decision text in code spans remain subject to the rule. An ID followed by `§` also names a heading of that file, judged by the same prefix rule as a section route.

The slug is GitHub's: link syntax, code-span backticks and HTML tags reduce to their text; ASCII letters lower-case (a non-ASCII letter keeps its case); every character not a letter, digit, space, `-` or `_` is dropped; each space becomes a hyphen; a repeat takes the first free `-1`, `-2` suffix.

A source file carries the same citations outside markdown, and they are judged there too:

- The `<path>.md § Heading` form in the COMMENT TEXT of any tracked file named by `COMMIT_GUARDS_MD_REFS_SOURCE_PATHS`, and in the STRING LITERALS of a TOML file as well, a quoted key among them: a manifest's text is its content, where a program's string literals are its data. Comment text and string literals come from the comments lane's extractor, so the grammars and their limits are § comments'.
- A decision ID there, but only where it carries a `§` heading, on the same rules.
- Nothing else. Outside markdown a link, a bare path and a bare decision ID are prose, and only `§` points a reader at a place in a file. The heading runs to the end of the line and the prefix rule judges it, so prose may follow it.
- One `git grep` over the index names the files this pass opens: a file whose bytes do not hold the section sign holds none of these citations, so it is counted without being read. A carrier whose content is binary is counted as unmeasured, as the other lanes count theirs. md-refs breaks its count out by reason on the summary line (`skipped=503 symlink=503`) and names one skipped path anyway where a judged reference lands on it; `--verbose` names every one.
- A carrier the extractor cannot read makes the lane exit 2. Its refusal carries the reader's `comment-reader:` cause and `citations=unjudged`: no citation in that file was judged, so the citation is not what to edit.

`--staged` and `--all` check every tracked file named by `COMMIT_GUARDS_MD_REFS_PATHS` or `COMMIT_GUARDS_MD_REFS_SOURCE_PATHS`, minus `COMMIT_GUARDS_MD_EXCLUDES`. `--base REF` and `--against REF` check that same set when the commit range carries any change, including a deletion, and nothing when it carries none; the dots are byte-ceiling's. With no flag, `COMMIT_GUARDS_MD_SCOPE=touched` checks the set when any change is staged, including deletions; `all` checks it unconditionally, and a range-scoped batch hands the lane `--all` under that setting rather than a range. Every scope that checks anything checks the whole set, so this includes references in unchanged documents. Callers and targets resolve against the index; a tracked path holding a newline is no link target.

## py-names

An undefined name in a Python file fails as `py-names: undefined-name=<path>:<line>`, exit 1. The rule is pyflakes' undefined name, ruff's `F821`; no other pyflakes rule is judged. A file the tool cannot parse fails as `py-names: invalid-syntax=<path>:<line>`, exit 1.

- The lane runs `ruff check --no-cache --isolated --ignore-noqa --target-version py314 --select F821`, so a project ruff configuration cannot switch the rule off and the builtins Python 3.14 defines are defined. No `noqa` comment suppresses a finding, under either tool. A ruff too old to know `py314` exits 2, which the lane reports as `tool-failed`, exit 2.
- Where `ruff` is not on `PATH`, the lane runs `python3 -P -W ignore -m pyflakes` and keeps its `undefined name` findings, less the `in __all__` variant, which is `F822`. `-P` keeps a module at the repository root from shadowing one pyflakes imports; a `python3` older than 3.11 has no `-P`, so the lane reports `tool-missing`. Stderr whose first line is not pyflakes' syntax error record is `tool-failed`, exit 2.
- The lane looks for a tool only once a file is selected. With a file selected and neither tool installed, it refuses with `py-names: tool-missing=ruff,pyflakes`, exit 2, and names the remedy on the following lines. A consumer's CI installs ruff, or pyflakes for python3, in a step ahead of the commit-guards step, under no condition the commit-guards step does not also carry. A tool exit past 1, or output the lane cannot read, is exit 2.
- Each blob is judged from a scratch copy under its own file name, so `__path__` stays defined in an `__init__.py`.

The lane selects `*.py`, minus the render paths `.kendex-generated.json` lists. It reads the inventory at the first `*.py` path the scope selects; a scope that selects none prints `py-names: no-match=<scope>:*.py` and exits 0 without reading the inventory or looking for a tool. `--staged`, the default, judges every Python file the staged diff adds, modifies or type-changes, in full, from the index. `--base REF` and `--against REF` judge the same over a commit range, on byte-ceiling's dots. `--all` judges every tracked Python file. A symlink, a gitlink or a binary blob at a selected path is counted as unmeasured. The batch hands the lane the scope it hands byte-ceiling: `--all`, `--staged`, or the range under every setting.

## secrets

A credential in a selected text file fails as `secrets: secret=<path>:<line>:<rule-id>`, exit 1. The rule id is gitleaks' own, such as `aws-access-token`. The lane never prints the matched value.

- The lane runs `gitleaks dir` with gitleaks' default rules (`[extend] useDefault = true`, passed by `--config`), `--redact` and `--ignore-gitleaks-allow`. The repository's `.gitleaks.toml` and `.gitleaksignore`, `GITLEAKS_CONFIG` and `GITLEAKS_CONFIG_TOML`, and inline `gitleaks:allow` comments switch no finding off. The one allowlist is `COMMIT_GUARDS_SECRETS_EXCLUDES`, overridden by `--excludes FILE`, whose rows each carry a reason.
- `--policy-root DIR` resolves that setting and reads the list from the repository at DIR instead of the one under judgement. CI passes its default-branch checkout, so a pull request's own exclusion rows and setting take effect after merge, not in the scan of that pull request. A row for a CI false positive lands on the default branch in its own pull request and clears later scans once merged. The lane still reads the judged repository's setting and list and refuses a malformed one, as at commit time, because it becomes the policy once merged. A policy root the lane cannot enter, or one outside any git repository, refuses as `secrets: policy-root=<dir>`, exit 2. Without the flag, as at commit time, the lane reads the repository's own list.
- An empty or missing value for `--policy-root`, `--excludes`, `--base` or `--against`, in the separate or the `=` form, refuses as `secrets: argument-missing=<option>`, exit 2, before any scan.
- Each selected blob is scanned whole from a scratch copy, so a rule that spans lines, such as a private key block, still matches. Under `--staged`, `--base REF` and `--against REF` a finding counts only where one of its lines is a line the diff adds. Under `--all` every finding counts.
- An excludes row is a path glob: it removes the whole file from every later scan, not the one match.
- The lane looks for gitleaks only once a file is selected, and probes it with `gitleaks dir --help`: `dir` is the subcommand the lane scans with, which gitleaks 8.19 added. With no `gitleaks` on `PATH` the lane prints `secrets: gap=gitleaks-missing:<count>`, and with one that fails the probe `secrets: gap=gitleaks-unusable:<count>`, `<count>` being the selected files left unscanned; it names the install command and exits 0, so a machine without the tool does not stop every commit. Under a non-empty `CI` or `GITHUB_ACTIONS`, a `--base`, `--against` or `--all` scan refuses instead, as `secrets: tool-missing=gitleaks` or `secrets: tool-unusable=gitleaks`, exit 2. `--staged` keeps the gap there: CI stages nothing to gate.
- A consumer's lane setup runs `.agents/skills/commit-guards/scripts/install-gitleaks "$HOME/.local/bin"` and puts that directory on `PATH`. The installer checks the release archive against its pinned checksum. CI calls the same installer before the scan, under no condition the scan does not also carry. The checkout carries the whole history (`actions/checkout` with `fetch-depth: 0`): a commit range's parents are what each commit is judged against.
- A gitleaks exit other than 0 or a leak is `secrets: tool-failed=gitleaks:<status>`, exit 2. A report the lane cannot read is `secrets: tool-output=jq:<status>`, and an added-line list it cannot read `secrets: added-read=<path>:<status>`, both exit 2.

`--staged`, the default, selects every file the staged diff adds, modifies or type-changes, renames held to exact content. `--base REF` and `--against REF` judge each commit HEAD holds and REF lacks, both kinds the same set, one blob per file the commit adds, modifies or type-changes against its first parent. A finding counts where its lines hold one the commit adds over each of its parents, so a credential a later commit removes still fails, a merge passes a match either parent carried whole, and a key block a merge completes from two parents' halves fails. A commit with no parent adds every line it holds. A commit whose parents a shallow clone never fetched refuses as `secrets: range-shallow=<commit>`, exit 2. The summary's `files` counts the blobs scanned. A range refusal names the commit; removing the line in a later commit leaves it in the pushed history. `--all` selects every tracked file. A symlink, a gitlink or a binary blob is counted as unmeasured. The batch hands the lane the scope it hands byte-ceiling, except that the pre-push hook withholds it under every scope: a push range would also hold every base commit landed since the last push, which the pusher cannot rewrite. So `secrets` does not run at push. A commit Git makes without running the pre-commit hook (a rebase, for one) gets no local scan: the CI range check judges it first, after the push has published it. A credential found there is rewritten out of the branch (`git rebase -i` on the commit that added it), the branch force-pushed, and the credential rotated.

## comments

A selected reference in the comment text of a scanned source file fails. `COMMIT_GUARDS_COMMENT_REFERENCE_TYPES` selects issue ids, three- or four-digit issue numbers, and calendar dates. It must name at least one type. Ordinary words do not trigger this check. Issue ids are checked only when `GH_ISSUE_PATTERN` declares a tracker pattern. An empty pattern leaves that type inactive; an ID-only scan then fails configuration. The issue id is matched as written, lowered and uppered, so a pattern written in one case matches the id in any case and a mixed-case pattern matches only its own spelling. A quoted example or backticked span inside the comment still counts. String literals and code are never judged. Each hit is reported once per line and shape. Without a tracker pattern, technical names such as `UTF-8` and `SHA-256` pass. Numeric issue references and dates remain checked by default. Each configured pattern is a POSIX ERE read by awk and `git grep`; one either tool cannot compile is exit 2.

Applied migrations are immutable first-party content; the exclusion policy is in [SKILL.md](SKILL.md) § Configuration.

Optional audit lane: run `.agents/skills/commit-guards/scripts/commit-guards comments` directly when an audit is needed. Keep `comments` out of `COMMIT_GUARDS_CHECKS` so it does not block commits. Scopes are `todo-ban`'s: `--staged` judges only the lines the staged diff adds, comment state read from the whole staged blob; the default reads every tracked file `COMMIT_GUARDS_COMMENT_PATHS` names minus `COMMIT_GUARDS_COMMENT_EXCLUDES`, overridden by `--excludes FILE`. A matched path the table below gives no grammar is counted as unmeasured.

Comment text is extracted per family, by extension or, for a path with none, by the interpreter its `#!` line names. The default path list is exactly these extensions, with `Makefile` and `Dockerfile` by basename at the root and below:

| Family | Extensions | Comments read | Strings tracked |
|---|---|---|---|
| C | `rs` `go` `c` `h` `cc` `cpp` `hpp` `java` `kt` `kts` `swift` `wgsl` `js` `mjs` `cjs` `jsx` `ts` `tsx` `scss` `less` | `//` `///` `//!` to end of line; `/* */` across lines | `"…"` and `'…'` with backslash escapes; a backtick template literal across lines (`go`, `js`, `ts` and their variants); Rust `r"…"`, `r#"…"#`, a string spanning lines, a char literal, and a lifetime quote that opens nothing |
| CSS | `css` | `/* */` only | `"…"` `'…'` |
| Hash | `sh` `bash` `zsh` `py` `rb` `toml` `yml` `yaml` `mk` `Makefile` `Dockerfile`; no extension with a `#!` naming an interpreter ending in `sh`, or python or ruby (`node`, `deno`, `bun` take the C family) | `#` at the start of a word (line start or after whitespace) to end of line; line 1 `#!` is not a comment | `"…"` with escapes; `'…'` without escapes in shell, TOML and YAML, with escapes in Python and Ruby; shell `$'…'` with escapes; a shell backslash outside a string quoting the next character, so the escaped quote in `'it'\''s'`, a `\'` case pattern or a `\"` in a `[[ =~ ]]` regex opens nothing; a shell string across lines; quotes, comments and heredocs inside a double-quoted `$(…)`; Python and TOML triple quotes across lines; a shell heredoc body (`<<WORD`, `<<-WORD`; the word runs to a blank or one of `;|&<>`, its quotes stripped; `<<` inside `((…))` is a shift) up to its terminator line |
| Dash | `sql` `lua` | `--` to end of line; SQL `/* */` and Lua `--[[ ]]` across lines | `"…"` `'…'` with escapes |
| Markup | `html` `htm` `xml` `svg` `vue` `svelte` | `<!-- -->` across lines | none |

The scanner is a character walk, not a parser. Its limits, each pinned by a control in [`tests/comments.test.sh`](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/tests/comments.test.sh):

- A `//` inside a JavaScript regex literal, a `#` glued to a Python or TOML value (`x = 1#c`), and a `--` inside a Lua long string `[[…]]` are read by the rules above, not the language's.
- A JavaScript template literal is one string to its closing backtick; a nested template inside `${…}` is not tracked.
- A Rust nested block comment closes at the first `*/`; a Lua `--[==[` level is not tracked.
- A `)` ending an unparenthesised `case` pattern inside a double-quoted `$(…)` closes the substitution, so a comment after that pattern is read as string text; a `(a)` pattern is tracked.
- A shell line opening two heredocs honours the first; a Ruby heredoc, a YAML block scalar (`key: |`) and a Makefile recipe's shell are read as code, so a `#` inside them is a comment.
- A Vue or Svelte file is judged for `<!-- -->` only; the `//` inside its script block is not read.
- A C or JavaScript string ends at its line (a trailing backslash continuation is not tracked); a Rust string does not.
- A file that ends inside a block comment, a heredoc body or a string spanning lines is unmeasured, and the refusal names the reader as the cause, `comment-reader:unclosed-string line=N` for a quote, with the opener's line. The remaining files are scanned before the lane exits 2. A JavaScript regex literal holding an odd number of backticks or quotes leaves the file in that state.

## commit-msg

One message, from FILE or stdin (FILE absent or `-`). Every applicable rule reports before the verdict.

- Shape: the header (the first non-blank, non-comment line) matches `type(scope)!: subject`, scope and `!` optional. Types are `COMMIT_GUARDS_COMMIT_TYPES`; the scope class `[#A-Za-z0-9 _.,/-]+` passes `fix(ABC-123):` and `fix(#123):`.
- Length: at most `COMMIT_GUARDS_SUBJECT_MAX` characters, counted as the changelog cap counts.
- Changelog: where `COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS` names a glob a changed path matches, the commit must also add or modify a program fragment under `COMMIT_GUARDS_CHANGELOG_PATHS` or carry `[no-changelog]` in the header. A [package entry](#fragments) is no entry for it, and the `changelog-missing` remedy names only the patterns that place program entries. Evidence is a path that comes out of the commit with content it did not carry there before (a new blob, a changed blob, a type that became a regular file, a rename destination); deleting a fragment is not writing one. `COMMIT_GUARDS_CHANGELOG_RECORD` counts only under `COMMIT_GUARDS_CHANGELOG_COLLATE=1`.

Both lists are read from `--raw` with rename detection pinned, against the parent the commit will have: HEAD, or HEAD's parent for an amend. An amend is read off the argv of the nearest `git` ancestor in `/proc/<pid>/cmdline`, only when `GIT_INDEX_FILE` says git started this hook; where nothing is readable (every macOS host) the parent is HEAD. `--amend` counts only where no value-taking option could have consumed it (`--mess --amend`, `-am --amend`, `--status --amend` are not amends); `--no-amend` counts wherever it stands; a bare `--` stops the scan. A rebase `reword` and an `edit` stop are amends; an all-`pick` rebase and an autosquash fixup are not.

Git-generated headers (Merge, Revert, Reapply, `fixup!`, `squash!`, `amend!`) skip shape and length and keep the changelog rule.
