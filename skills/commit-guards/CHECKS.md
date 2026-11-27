# commit-guards checks

What each check fails, its scopes and flags, the keys it reads, and the grammar a test pins. Invocation and hooks: [README.md](README.md); settings reference: [Configuration](SKILL.md#configuration).

- Every check exits `0` clean, `1` violations, `2` usage, config or collection error. An unmerged scanned path is a collection error.
- Scans read index content, and content decides what is read: an attributes rule cannot hide a path.
- A symlink, a submodule gitlink, or a blob with a NUL in its leading bytes at a scanned path is counted as unmeasured, never folded into a clean count. The verdict line carries that count and names no path. md-refs alone names a path: the one a judged reference lands on, or every one under its `--verbose`.
- Excludes lists and baselines take the formats in [hooks and settings § Exclusions and baselines](references/hooks-and-settings.md#exclusions-and-baselines).
- A path-glob list replaces the default. The md-refs settings add each matching EXTRA list before validation.
- An empty effective list is a config error; a list matching no tracked file is a clean pass.

## byte-ceiling

A tracked binary or non-text file a change puts over `COMMIT_GUARDS_BYTE_CEILING_KB` (KB = 1024 bytes) fails; size is the blob's object size. An existing file already over the ceiling may stay the same size or shrink, but may not grow. A lockfile is exempt by exact basename; `LOCKFILE_BASENAMES` in `scripts/byte-ceiling` lists the names. Asset trees go in `COMMIT_GUARDS_BYTE_EXCLUDES`, overridden by `--excludes FILE`.

Text and source files have no ceiling. The shared Git binary classifier checks content rather than names or attributes.

A binary file not over the ceiling but at or above `COMMIT_GUARDS_BYTE_WARN_PCT` percent of it prints `near-ceiling` naming the path, its bytes, the ceiling in bytes and the percent reached, and does not fail. The percent must be 1-100; any other value is a configuration error.

- `--staged` (default): files added, modified or type-changed in the staged diff, renames held to exact content.
- `--base REF`: files added, modified or type-changed since the merge-base with REF — three dots, so the baseline is the blob REF and HEAD share.
- `--against REF`: the same files between REF's own tree and HEAD — two dots, so the baseline is REF's own blob. Where REF is an ancestor of HEAD the two scopes agree. Where they have diverged they do not, and only this one measures what landing HEAD at REF would do to REF: a file over the ceiling at the shared ancestor, smaller at REF and larger at HEAD, is a shrink to `--base` and growth to `--against`.
- `--all`: every tracked file. A sweep has no source blob, so an oversized file's prior is its row in `COMMIT_GUARDS_BYTE_BASELINE` (`path<TAB>bytes`, read from the index), overridden by `--baseline FILE`. A file at its row passes, one past its row fails as growth, and one with no row fails as oversized. Rows naming text files are ignored. Every other row larger than its file fails `baseline-loose`, and every other row naming no oversized binary file the sweep judges fails `baseline-stale`, so the binary baseline only tightens.

The batch names the scope: `commit-guards all` hands the lane `--all`, `all --base REF` hands `--base REF`, `all --against REF` hands `--against REF`, `all --staged` hands `--staged`. byte-ceiling takes a range under every setting. The two range scopes also reach md-type and md-refs, on the same dot conventions; § md-type and § md-refs state when each takes them. A copy is an addition; symlinks and gitlinks are not sized.

## conflict-markers

Seven `<`, seven `|`, or seven `>` at column 0, followed by a space or end of line, fail in every tracked file. Indented or quoted occurrences and the seven-`=` separator do not fire. `--excludes FILE` overrides `COMMIT_GUARDS_CONFLICT_EXCLUDES`. The render paths `.kendex-generated.json` lists are not judged, read at the first file carrying a marker; an inventory that cannot be read follows [hooks and settings § Generated-file exclusions](references/hooks-and-settings.md#generated-file-exclusions).

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

### Classify

`--classify PATH...` judges nothing: it prints one line per path, in argument order, of what the settings make it, a tab, then the path. The kinds are `record` (the configured record, or the `CHANGELOG.md` a [package `package.json`](#version-bumps) reads), `fragment`, `version` (a `COMMIT_GUARDS_CHANGELOG_VERSION_PATHS` file), `package` (a declared package file), `render` (a path the staged `.kendex-generated.json` lists) and `none`; the first that applies wins. The orch skill's restack check (`orch-runtime validate entry`) reads it to know what each conflicted file is.

`--unversion` judges nothing either: it prints the JSON version file on stdin, as jq prints it, less the top-level `version` the [version-bump check](#version-bumps) reads, through the same jq path. A nested `version`, such as an npm `scripts.version`, is kept. Input jq cannot delete that field from exits 2. The orch skill's restack check compares two sides of a version file through it.

### Release versions

A repository that releases chooses each version by this rule. Where `COMMIT_GUARDS_CHANGELOG_VERSION_PATHS` or `COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS` is set, the [version-bump check](#version-bumps) refuses the increases it lists, and judges a minor or a patch only from 1.0.

- The program's version reads the program's entries alone. A package's entry, a package fragment or an item under the record's `### Packages`, proposes no program version, whatever its section or Breaking mark.
- A package that states a version versions on its own: each commit that changes it raises its version by this rule against that commit's own package entries. A versionless package's entries release under its name alone.
- From 1.0, fixes, internal changes, refactors, tests and docs are a patch. A minor needs a new user-facing capability or a consumer-visible setting. A breaking change is a major and needs the owner's approval.
- Before 1.0, a minor marks a break and a patch holds everything else.
- An `added/` fragment names only something a consumer of the repository uses. Internal tooling and tests go under `changed/`, or carry no fragment where [commit-msg](#commit-msg) owes none.
- A critical fix (broken install, data loss, security, a blocked consumer) ships promptly and is never held for a batch.
- When several critical fixes are open or in flight, they land together in one release, not one release each.
- Otherwise, cut at most one release a day, batching what has merged.

### Version bumps

- `COMMIT_GUARDS_CHANGELOG_VERSION_PATHS` selects tracked JSON files by space-separated path globs. Empty, the default, disables version checks. A selected changed file must be regular JSON with a string `version` in `major.minor.patch` form, with optional prerelease and build suffixes. jq reads both versions. Missing jq or unreadable versions are collection errors.
- The default and `--staged` compare the commit's parent to the index: HEAD, or HEAD's parent in an amend, read as [commit-msg](#commit-msg) reads it, so HEAD where the committing argv is unreadable. `--base REF` compares HEAD's merge base with REF to the index. `--against REF` compares REF itself to the index. The batch passes its range to this lane, or `--against` the ref a `--history REF` caller names; the push hook withholds this lane because merge-group CI owns the range judgment. Fragment validation always reads the whole index. A newly added version file has no prior version to increase.
- The publishing caller uses `--release REF` for its selected merge commit. Before discovery, this mode reads tracked policy through the existing index-scoped settings loader with a private index of that tree. It leaves the caller's index and working tree unchanged. The selected program version's nonzero patch component means patch; otherwise a nonzero minor component means minor; otherwise major. Suffixes do not change that level. A selected program version below 1.0 is exempt from the minor and patch judgments, as in the version-change check. This check judges only pending program fragments against that level, without reading release records or comparing historical versions. Unchanged-version re-collation and independent package releases do not change its scope.
- jq compares the `major.minor.patch` numbers with the suffixes removed, so the bump is the first number that increased; a suffix change alone, or a decrease, is no bump.
- A Breaking entry is a list item starting `- **Breaking:**`, or `- **Breaking**:` as the Pi package records write it, followed by non-blank text. An increased major fails with `major-breaking=PATH:OLD:NEW` unless its release holds a Breaking entry. The check cannot judge whether the text describes the actual break or gives a sufficient migration note.
- From 1.0, a prior major of 1 or more, a minor increase fails with `minor-breaking=PATH:OLD:NEW` when its release holds a Breaking entry. A patch increase fails with `patch-added=PATH:OLD:NEW` when its release holds an Added entry and with `patch-breaking=PATH:OLD:NEW` when it holds a Breaking entry. An Added entry is an `added/` fragment or an item directly under the record's `### Added` heading. Each refusal's next record is `entry-preview=`, the first such entry's first line. Below 1.0 neither increase is judged.
- A `package.json` outside the directory of `COMMIT_GUARDS_CHANGELOG_RECORD`, or any `package.json` while the record is off, is a package and uses only its adjacent `CHANGELOG.md`: `### Unreleased` before release, or `### <new version>` as the first release section after the release renames that heading. Another package's call-out does not count. A package record has no Added section, so a package patch takes the Breaking refusal only.
- Other version files, a `package.json` beside the record included, use an accepted program fragment or the configured record's `## [Unreleased]` or the first release section, `## [<new version>] - <date>`, less its `### Packages` part. This permits the release commit after collation deletes fragments and the caller sets the version. Past versions and fenced examples do not count. An unreadable record fails closed.
- Once a record holds the new version's own section, that section supplies its release notes. A major must name its break in that section and cannot borrow a pending Breaking entry. In staged and merge-base checks, pending fragments and pending record entries must also fit the version's level: Added needs at least a minor, Breaking a major. A refusal names the offending path and required level. Compatible pending entries can wait for the next release. This applies to package records too. Historical `--against` checks use the named release's entries alone, so an inherited release bump after a restack does not claim later pending entries. Without a matching release section, the program reads its pending fragments and pending record section. Publishing uses the narrower pending-fragment check above.
- `COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS` declares packages by space-separated path globs; empty, the default, disables package entries and the package check.
  - A selected `SKILL.md` names its directory and versions it where its frontmatter states a `metadata.version`: `skills/linear/SKILL.md` versions `skills/linear/` and reads `changelog.d/linear/`. One whose frontmatter holds no version key in any spelling declares a versionless package.
  - Any other selected file names itself less its extension and carries no version: `hooks/command-safety.sh` declares `command-safety`.
  - A glob selects a file at its own depth only, so `hooks/*.sh` leaves `hooks/tests/lib/assert.sh` undeclared.
  - Two package files declaring one name are a collection error, `package-duplicate=FIRST:SECOND`.
  - A versioned package's version is its frontmatter `metadata.version`, stated as `metadata:` then an indented `version: X` line, its value plain, double-quoted or single-quoted, in the same form.
  - A package file the check reads without a frontmatter `name` is a collection error.
  - So is one holding a version key, at a line's start or after a flow mapping's `{` or `,`, quoted or not, with space before its colon or none, where that form states no non-empty version: a flow mapping, a quoted key, a space before the colon, an empty value, or a `version:` line outside `metadata:` and none within it. The word `version` inside a value is no key.
  - A YAML comment line inside `metadata:` neither ends the block nor counts as a version line, and the `metadata:` line may carry a trailing comment.
- Each commit that changes a versioned package raises its version. A diff touching any path under its directory must raise it, or fails with `package-unbumped=PATH:OLD`; a newly added package file, or one stating its first version, has no prior version to raise, a change that drops the version leaves a versionless package, and a package fragment alone touches no package directory. The raise is judged as above against the package fragments that same diff adds, never a fragment an earlier change added, whose release that was, even where this diff edits it. Every scope reads the diff the scope bullet above names.

## md-type

Fails a Markdown file the block parser cannot end. Every selected file is parsed by `scripts/lib/md-blocks.awk`, the grammar md-refs and md-reflow read by. A fence, front matter, an HTML block or a prompt-section block left open fails, keyed by md-blocks' refusal (`fence-unclosed=<path>:<line>`). No reader can read such a file past that line:

- [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) § 4.5 and § 4.6 run an unclosed fence or HTML block to the end of the document. A renderer shows the rest as code, and a browser hides the rest behind an unclosed `<!--`.
- md-refs judges no reference in the file and names it `unjudged=`, so a dead reference past the construct goes unreported. md-type is that construct's gate (§ md-refs).

CRLF line ends are normalized, not judged. The lane reads no docs-writing file.

`--route` and `--as` read docs-writing's route table as data:

- The table is the one under docs-writing's `## Per file type` whose header is `Path | Section | Example`.
- A table with a fourth `Shape` column, the retired form, is read with that column ignored until the next major release, and prints one `warning=route-table-shape path=<file>:<line>` on stderr.
- docs-writing is found the way the pre-commit chain finds a sibling gate: the judged tree's install first, then the copy beside this package.
- The first row with a code-span glob matching the repo-relative path wins; `*` crosses `/`.
- `--as` prints one size line for a classified path whose row names an example, which docs-audit relays. Size is the file's words outside front matter and code blocks, beside the words of the row's example document counted the same way. The example document is the content of the example's first `markdown` fence before any thematic break, else the example up to its first thematic break. Size is a signal only and never changes the exit status.

```
md-type: signal=size path=<p> type=<t> words=<n> example_words=<n> example=<file>
```

Exits:

- An unended file exits 1 in the lane scopes and under `--as`.
- With no docs-writing, `--as` and `--route` print `gap=docs-writing-missing` and exit 2.
- Where docs-writing breaks the route-table contract, `--as` and `--route` print `rules=unreadable detector=<d> path=<file>` and exit 2, so the audit never reports an unread rule set clean.

The detectors are `unended` (a SKILL.md the block parser cannot end), `route-table` (no such table, or more than one), `cells` and `type` (a row the table contract cannot read), `link` (a linked reference or example missing), `example` (an example document the block parser cannot end), and `floor` (no row classifies `README.md`, or none routes to both a reference and an example).

Scopes and modes:

- md-type's scopes, from `scripts/lib/md-scope.sh`, are `--staged`, `--base REF`, `--against REF` and `--all` over `COMMIT_GUARDS_MD_PATHS` minus `COMMIT_GUARDS_MD_EXCLUDES`, renders excluded as [hooks and settings § Generated-file exclusions](references/hooks-and-settings.md#generated-file-exclusions) states. With no flag, `COMMIT_GUARDS_MD_SCOPE` decides.
- Under `--staged`, `--base` and `--against`, md-type alone parses every moved file at its new path, an unchanged move included, so a file moved into `COMMIT_GUARDS_MD_PATHS` is parsed where it arrives. `--all` parses every matching tracked file.
- The batch hands it `--staged` at commit and the range a caller hands under either `COMMIT_GUARDS_MD_SCOPE`, or `--against` the ref a `--history REF` caller names. Push withholding is defined in [hooks and settings § Pre-push scope](references/hooks-and-settings.md#pre-push-scope).
- `--route PATH` prints `type=`, `reference=` and `example=` lines, or `route=ignored`, `route=outside-repo`, or `route=unclassified` with `skill=`. It runs only `git rev-parse` and `git check-ignore` in the path's repository. A path under a `.git` entry that git cannot read, or where git cannot run, is exit 2 `route-repo=<dir>` with git's message.
- `[--root REPO] --as PATH FILE` parses and sizes FILE, `-` for stdin, as PATH with docs-writing read from REPO's install first. Repeated pairs are read in order with the route table read once, each followed by `judged=<n>`.

## md-reflow

`md-reflow` writes a markdown file in one format: one paragraph per line and one list item per line, blank lines between paragraphs, list blocks, headings and fences, and no trailing-double-space break. No lane refuses a file off the format; `md-reflow --check` names one.

The grammar is `scripts/lib/md-blocks.awk`'s, with the line-shape predicates in `scripts/lib/md-shapes.awk`; md-reflow, md-refs and md-type read by that pair:

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

`scripts/md-reflow [--check] PATH...`, or `--staged` or `--all` over the files `scripts/lib/md-scope.sh` selects from `COMMIT_GUARDS_MD_PATHS` minus `COMMIT_GUARDS_MD_EXCLUDES`, rewrites the work-tree copy:

- The lines of a paragraph, a list item and a blockquote paragraph join with single spaces, and a trailing-double-space break joins away.
- A missing blank line goes before a heading, fence or list that follows a paragraph line, on both sides of a heading, and after a fence closer.
- `--staged` holds renames to exact content, so an unchanged move is not taken; `--all` takes every matching tracked file, an unchanged move included.
- Skipped blocks and one-line definitions come out byte-identical, as does a clean file; a file with no trailing newline keeps none. A second rewrite changes nothing.
- `--check` writes nothing and exits 1 naming each file a rewrite would change.
- A CRLF file, a symlink and a file holding a NUL are refused at exit 2.
- A PATH is taken from the current directory and must lie inside the repository.

## md-refs

A dead reference in a scanned markdown file fails. A citing file at or below a path in the indexed `.kendex-lock.json` `emitted.paths` warns instead, with the citing file, target and `kendex report` command. A link or citation from any other file into a path at or below an emitted path is not judged, neither its path nor its heading. A citation between the repository's own files is judged in full. `--strict` reads no lock, so it judges every reference and makes rendered-file references fail too; the catalog install-layout test uses it. An absent lock lists no paths; a scan that reads an unreadable or malformed lock exits 2. Fenced code, indented code and front matter are never read. Forms:

- A link or reference definition whose destination is relative (no scheme, no leading `/`, not `mailto:`) must name a tracked file or directory, resolved against the citing file's directory; `..` above the repository root is dead. With `#anchor`, the target must be markdown and the anchor one of its heading slugs or an explicit `<a id="...">` or `<a name="...">`; a bare `#anchor` resolves in the citing file. A definition is read only where the line begins with its `[label]:`.
- A code span holding `<path>.md § Heading` must name a tracked file with a heading equal to `Heading` case-insensitively after trimming; one holding `<path>.md#anchor` a tracked file with that slug or explicit anchor. The path resolves against the citing file's directory, then the repository root. A path alone in a code span is not judged.
- A code span holding `<path>::<phrase>` is a content citation, read where the text before the first `::` holds a `/` and is spelled from `A-Za-z0-9`, `.`, `_`, `-` and `/` alone, and the phrase after it is not empty. The path resolves as the citation above does and must name a tracked file; that file's bytes must hold the phrase, byte for byte, as a literal substring. This proves the cited file still carries the text the sentence quotes and nothing about what the text means: no test name is parsed and no framework is known. A path in a code span with no `::` phrase stays a name. A citation into binary content is exit 2. A `§` in the span wins, so `<path> § Heading` is never read as a content citation; the form is read in Markdown only, never in comment text or a TOML string.
- A relative markdown link followed by `§` must start with an existing heading name from that target. Matching ignores case, backticks, and emphasis markers. The heading name ends at a word boundary; prose can follow it. A section number also resolves to a heading with that number. Text routes check a heading prefix. Use an anchor link or an exact code-span citation where heading names share a prefix.
- A decision ID, `DECISION_ID_PREFIX` plus at least `DECISION_ID_WIDTH` digits bounded by non-alphanumerics, must name a tracked file `DECISIONS_DIR/<ID>-*.md`. The tracked `DECISIONS_DIR/INDEX.md` reserves the ID in the second cell of a row opening `| YYYY-` only within that row. A bare ID outside its row still needs a tracked record. Where that directory is not tracked, IDs are not judged and the verdict says so. IDs inside a complete inline link with a non-local destination (a scheme or leading `/`) are excluded, in both its label and destination. Bare IDs, IDs in relative links and decision text in code spans remain subject to the rule. Links in a reserved row still need valid targets and anchors. An ID followed by `§` also names a heading of its document, judged by the same prefix rule as a section route, and fails when the document is absent.

The slug is GitHub's: link syntax, code-span backticks and HTML tags reduce to their text; ASCII letters lower-case (a non-ASCII letter keeps its case); every character not a letter, digit, space, `-` or `_` is dropped; each space becomes a hyphen; a repeat takes the first free `-1`, `-2` suffix.

A source file carries the same citations outside markdown, and they are judged there too:

- The `<path>.md § Heading` form in the COMMENT TEXT of any tracked file named by `COMMIT_GUARDS_MD_REFS_SOURCE_PATHS`, and in the STRING LITERALS of a TOML file as well, a quoted key among them: a manifest's text is its content, where a program's string literals are its data. The default uses `GG_COMMENT_PATHS_DEFAULT` in `scripts/lib/comment-text.sh`. Set `COMMIT_GUARDS_MD_REFS_SOURCE_PATHS_EXTRA='*'` to include extensionless scripts. A selected extensionless script takes its comment grammar from its shebang. Remove an interim `COMMIT_GUARDS_MD_REFS_SOURCE_PATHS` override that only restored the extension-list default. Markdown files use the document pass. Comment text and string literals come from the extractor in `scripts/lib/comment-text.sh`, so the grammars and their limits are § comments'. A carrier with no comment grammar is counted as unmeasured.
- A decision ID there, but only where it carries a `§` heading, on the same rules.
- Nothing else. Outside markdown a link, a bare path and a bare decision ID are prose, and only `§` points a reader at a place in a file. The heading runs to the end of the line and the prefix rule judges it, so prose may follow it.
- One `git grep` over the index names the files this pass opens: a file whose bytes do not hold the section sign holds none of these citations, so it is counted without being read. A carrier whose content is binary is counted as unmeasured, as the other lanes count theirs. md-refs breaks its count out by reason on the summary line (`skipped=503 symlink=503`) and names one skipped path anyway where a judged reference lands on it; `--verbose` names every one.
- A carrier the extractor cannot read is named `extraction=<path>:<cause>` with the reader's `comment-reader:` cause and `citations=unjudged`, and counted on the summary line as `extraction`: no citation in that file was judged, so the citation is not what to edit. The run does not fail for it.

A Markdown file the block parser cannot end, a fence, front matter or block left open, is named `unjudged=<rule>:<path>:<line>` and counted as `malformed`; md-type is the gate for that construct. A heading or anchor reference into a target the parser cannot end prints `unmeasured=<target>:unread` in place of a dead verdict. `--strict` refuses each of these as `incomplete=files=<n>`, exit 2: the catalog install check is where a package's author judges its own files.

`--staged` and `--all` check every tracked file named by `COMMIT_GUARDS_MD_REFS_PATHS` or `COMMIT_GUARDS_MD_REFS_SOURCE_PATHS`, each with the globs its `_EXTRA` setting adds, minus `COMMIT_GUARDS_MD_EXCLUDES`. `--base REF` and `--against REF` check that same set when the commit range carries any change, including a deletion, and nothing when it carries none; the dots are byte-ceiling's. With no flag, `COMMIT_GUARDS_MD_SCOPE=touched` checks the set when any change is staged, including deletions; `all` checks it unconditionally, and a range-scoped batch hands the lane `--all` under that setting rather than a range. Every scope that checks anything checks the whole set, so this includes references in unchanged documents. Callers and targets resolve against the index; a tracked path holding a newline is no link target.

## py-names

An undefined name in a Python file fails as `py-names: undefined-name=<path>:<line>`, exit 1. The rule is pyflakes' undefined name, ruff's `F821`; no other pyflakes rule is judged. A file the tool cannot parse fails as `py-names: invalid-syntax=<path>:<line>`, exit 1.

- The lane runs `ruff check --no-cache --isolated --ignore-noqa --target-version py314 --select F821`, so a project ruff configuration cannot switch the rule off and the builtins Python 3.14 defines are defined. No `noqa` comment suppresses a finding, under either tool. A ruff too old to know `py314` fails the probe below and is `tool-unusable`.
- Where `ruff` is not on `PATH`, the lane runs `python3 -P -W ignore -m pyflakes` and keeps its `undefined name` findings, less the `in __all__` variant, which is `F822`. `-P` keeps a module at the repository root from shadowing one pyflakes imports; a `python3` older than 3.11 has no `-P`, so the lane reports `tool-missing`. Stderr whose first line is not pyflakes' syntax error record is `tool-failed`, exit 2.
- The lane looks for a tool only once a file is selected, and probes each on a clean file: a ruff too old to know `py314`, or a pyflakes that fails, is unusable.
- With a file selected and no usable tool, the lane prints `py-names: gap=tool-missing:<count>` or `py-names: gap=tool-unusable:<count>`, `<count>` being the selected files left unjudged, names the remedy and exits 0.
- Under a non-empty `CI` or `GITHUB_ACTIONS`, a `--base`, `--against` or `--all` scan refuses instead, as `py-names: tool-missing=ruff,pyflakes` or `py-names: tool-unusable=ruff,pyflakes`, exit 2. `--staged` keeps the gap there.
- A consumer's CI installs ruff, or pyflakes for python3, in a step ahead of the commit-guards step, under no condition the commit-guards step does not also carry.
- `install-git-hooks` names a missing tool at setup, as `tool-missing=ruff,pyflakes`, where the repository tracks Python files.
- A tool exit past 1 after the probe, or output the lane cannot read, is exit 2.
- Each blob is judged from a scratch copy under its own file name, so `__path__` stays defined in an `__init__.py`.

The lane selects `*.py`, minus the render paths `.kendex-generated.json` lists. It reads the inventory at the first `*.py` path the scope selects; a scope that selects none prints `py-names: no-match=<scope>:*.py` and exits 0 without reading the inventory or looking for a tool. `--staged`, the default, judges every Python file the staged diff adds, modifies or type-changes, in full, from the index. `--base REF` and `--against REF` judge the same over a commit range, on byte-ceiling's dots. `--all` judges every tracked Python file. A symlink, a gitlink or a binary blob at a selected path is counted as unmeasured. The batch hands the lane the scope it hands byte-ceiling: `--all`, `--staged`, or the range under every setting.

## secrets

A credential in a selected text file fails as `secrets: secret=<path>:<line>:<rule-id>`, exit 1. The rule id is gitleaks' own, such as `aws-access-token`. The lane never prints the matched value.

- The lane runs `gitleaks dir` with gitleaks' default rules (`[extend] useDefault = true`, passed by `--config`), `--redact` and `--ignore-gitleaks-allow`. The repository's `.gitleaks.toml` and `.gitleaksignore`, `GITLEAKS_CONFIG` and `GITLEAKS_CONFIG_TOML`, and inline `gitleaks:allow` comments switch no finding off. The one allowlist is `COMMIT_GUARDS_SECRETS_EXCLUDES`, overridden by `--excludes FILE`, whose rows each carry a reason.
- `--policy-root DIR` resolves that setting and reads the list from the repository at DIR instead of the one under judgement. CI passes its default-branch checkout, so a pull request's own exclusion rows and setting take effect after merge, not in the scan of that pull request. A row for a CI false positive lands on the default branch in its own pull request and clears later scans once merged. The lane still reads the judged repository's setting and list and refuses a malformed one, as at commit time, because it becomes the policy once merged. A policy root the lane cannot enter, or one outside any git repository, refuses as `secrets: policy-root=<dir>`, exit 2. Without the flag, as at commit time, the lane reads the repository's own list.
- An empty or missing value for `--policy-root`, `--excludes`, `--base` or `--against`, in the separate or the `=` form, refuses as `secrets: argument-missing=<option>`, exit 2, before any scan.
- Each selected blob is scanned whole from a scratch copy, so a rule that spans lines, such as a private key block, still matches. Under `--staged`, `--base REF` and `--against REF` a finding counts only where one of its lines is a line the diff adds. Under `--all` every finding counts.
- An excludes row is a path glob: it removes the whole file from every later scan, not the one match.
- The lane looks for gitleaks only once a file is selected, and probes it with `gitleaks dir --help`: `dir` is the subcommand the lane scans with, which gitleaks 8.19 added.
- With no `gitleaks` on `PATH` the lane prints `secrets: gap=gitleaks-missing:<count>`, and with one that fails the probe `secrets: gap=gitleaks-unusable:<count>`, `<count>` being the selected files left unscanned; it names the install command and exits 0.
- Under a non-empty `CI` or `GITHUB_ACTIONS`, a `--base`, `--against` or `--all` scan refuses instead, as `secrets: tool-missing=gitleaks` or `secrets: tool-unusable=gitleaks`, exit 2. `--staged` keeps the gap there.
- A consumer's lane setup runs `.agents/skills/commit-guards/scripts/install-gitleaks "$HOME/.local/bin"` and puts that directory on `PATH`. The installer checks the release archive against its pinned checksum.
- CI calls the same installer before the scan, under no condition the scan does not also carry.
- The CI checkout carries the whole history (`actions/checkout` with `fetch-depth: 0`): a commit range's parents are what each commit is judged against.
- A gitleaks exit other than 0 or a leak is `secrets: tool-failed=gitleaks:<status>`, exit 2. A report the lane cannot read is `secrets: tool-output=jq:<status>`, and an added-line list it cannot read `secrets: added-read=<path>:<status>`, both exit 2.

Scopes:

- `--staged`, the default, selects every file the staged diff adds, modifies or type-changes, renames held to exact content.
- `--base REF` and `--against REF` judge each commit HEAD holds and REF lacks, both kinds the same set, one blob per file the commit adds, modifies or type-changes against its first parent.
- In a range, a finding counts where its lines hold one the commit adds over each of its parents. A credential a later commit removes still fails, a merge passes a match either parent carried whole, and a key block a merge completes from two parents' halves fails. A commit with no parent adds every line it holds.
- A commit whose parents a shallow clone never fetched refuses as `secrets: range-shallow=<commit>`, exit 2.
- The summary's `files` counts the blobs scanned.
- A range refusal names the commit; removing the line in a later commit leaves it in the pushed history.
- `--all` selects every tracked file.
- A symlink, a gitlink or a binary blob is counted as unmeasured.
- The batch hands the lane the scope it hands byte-ceiling, except that the pre-push hook withholds it under every scope. So `secrets` does not run at push.
- A commit Git makes without running the pre-commit hook (a rebase, for one) gets no local scan: the CI range check judges it first, after the push has published it.
- A credential found there is rewritten out of the branch (`git rebase -i` on the commit that added it), the branch force-pushed, and the credential rotated.

## comments

The comment extractor md-refs reads for its source-file citations, in `scripts/lib/comment-text.sh`. It is not a check.

Comment text is extracted per family, by extension or, for a path with none, by the interpreter its `#!` line names. md-refs' default source list, `GG_COMMENT_PATHS_DEFAULT`, is exactly these extensions, with `Makefile` and `Dockerfile` by basename at the root and below:

| Family | Extensions | Line comment | Block comment |
|---|---|---|---|
| C | `rs` `go` `c` `h` `cc` `cpp` `hpp` `java` `kt` `kts` `swift` `wgsl` `js` `mjs` `cjs` `jsx` `ts` `tsx` `scss` `less` | `//` `///` `//!` | `/* */` |
| CSS | `css` | none | `/* */` |
| Hash | `sh` `bash` `zsh` `py` `rb` `toml` `yml` `yaml` `mk` `Makefile` `Dockerfile` | `#` | none |
| Dash | `sql` | `--` | `/* */` |
| Dash | `lua` | `--` | `--[[ ]]` |
| Markup | `html` `htm` `xml` `svg` `vue` `svelte` | none | `<!-- -->` |

- A line comment runs to the end of its line. A block comment may span lines.
- A path with no extension takes its family from the interpreter its `#!` line names: an interpreter whose name ends in `sh`, or python or ruby, takes the Hash family; `node`, `deno` and `bun` take the C family.
- A Hash `#` opens a comment only at the start of a word: at line start or after whitespace. The line 1 `#!` is not a comment.

The strings each family tracks:

- C: `"…"` and `'…'` with backslash escapes; a backtick template literal across lines (`go`, `js`, `ts` and their variants); Rust `r"…"`, `r#"…"#`, a string spanning lines, a char literal, and a lifetime quote that opens nothing.
- CSS: `"…"` and `'…'`.
- Hash:
  - `"…"` with escapes.
  - `'…'` without escapes in shell, TOML and YAML, with escapes in Python and Ruby.
  - Shell `$'…'` with escapes.
  - A shell backslash outside a string quotes the next character, so the escaped quote in `'it'\''s'`, a `\'` case pattern or a `\"` in a `[[ =~ ]]` regex opens nothing.
  - A shell string across lines.
  - Quotes, comments and heredocs inside a double-quoted `$(…)`.
  - Python and TOML triple quotes across lines.
  - A shell heredoc body (`<<WORD`, `<<-WORD`) up to its terminator line. The word runs to a blank or one of `;|&<>`, its quotes stripped; `<<` inside `((…))` is a shift.
- Dash: `"…"` and `'…'` with escapes.
- Markup: none.

In JavaScript and TypeScript code state, a slash that does not begin `//` or `/*`, preceded on its line only by whitespace, `if`, optional whitespace, `(` and optional whitespace, opens a same-line regex body. Escapes skip the next byte; bracket classes keep their slashes inside the body. Quotes, backticks and comment leaders in that body are data. Only an unescaped slash outside a class closes it. A missing same-line closer leaves the file unmeasured with `comment-reader:unclosed-regex line=N`.

The scanner is a character walk, not a parser. Its limits, each pinned by a control in [`tests/comments.test.sh`](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/tests/comments.test.sh):

- Outside the leading `if (` form above, a `//` inside a JavaScript regex literal, a `#` glued to a Python or TOML value (`x = 1#c`), and a `--` inside a Lua long string `[[…]]` are read by the rules above, not the language's.
- A JavaScript template literal is one string to its closing backtick; a nested template inside `${…}` is not tracked.
- A Rust nested block comment closes at the first `*/`; a Lua `--[==[` level is not tracked.
- A `)` ending an unparenthesised `case` pattern inside a double-quoted `$(…)` closes the substitution, so a comment after that pattern is read as string text; a `(a)` pattern is tracked.
- A shell line opening two heredocs honours the first; a Ruby heredoc, a YAML block scalar (`key: |`) and a Makefile recipe's shell are read as code, so a `#` inside them is a comment.
- A Vue or Svelte file is judged for `<!-- -->` only; the `//` inside its script block is not read.
- A C or JavaScript string ends at its line (a trailing backslash continuation is not tracked); a Rust string does not.
- A file that ends inside a block comment, a heredoc body or a string spanning lines is unmeasured, and the refusal names the reader as the cause, `comment-reader:unclosed-string line=N` for a quote, with the opener's line. Outside the leading `if (` form above, a JavaScript regex literal holding an odd number of backticks can leave the file in that state.

## commit-msg

One message, from FILE or stdin (FILE absent or `-`).

- Where `COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS` names a glob a changed path matches, the commit must also add or modify a program fragment under `COMMIT_GUARDS_CHANGELOG_PATHS` or carry `[no-changelog]` in the header, the first non-blank, non-comment line.
- A [package entry](#fragments) is no entry for it, and the `changelog-missing` remedy names only the patterns that place program entries.
- Evidence is a path that comes out of the commit with content it did not carry there before (a new blob, a changed blob, a type that became a regular file, a rename destination); deleting a fragment is not writing one.
- `COMMIT_GUARDS_CHANGELOG_RECORD` counts only under `COMMIT_GUARDS_CHANGELOG_COLLATE=1`.
- The rule runs over every header, a git-generated one (Merge, Revert, `fixup!`) included.

The parent:

- Both lists are read from `--raw` with rename detection pinned, against the parent the commit will have: HEAD, or HEAD's parent for an amend.
- An amend is read off the argv of the nearest `git` ancestor in `/proc/<pid>/cmdline`, only when `GIT_INDEX_FILE` says git started this hook. Where nothing is readable (every macOS host) the parent is HEAD.
- `--amend` counts only where no value-taking option could have consumed it (`--mess --amend`, `-am --amend`, `--status --amend` are not amends); `--no-amend` counts wherever it stands; a bare `--` stops the scan.
- A rebase `reword` and an `edit` stop are amends; an all-`pick` rebase and an autosquash fixup are not.

## The run log

Each batch run appends one row per check it runs to `kendex/lane-data/commit-guards-runs.tsv` under the directory that `git rev-parse --git-common-dir` reports. Linked worktrees and the main checkout share the log outside their working trees. No setting turns it on and nothing leaves the machine. A row is six tab-separated fields:

1. The start: whole epoch seconds when the check started.
2. The check's name.
3. The batch scope: `staged`, `all`, `base` or `against`.
4. The outcome: `clean` for exit 0, `violations` for exit 1, `incomplete` for any other exit.
5. The wall time in seconds to three decimals, or `unmeasured` where the clock could not be read. The clock is GNU `date`, else perl's `Time::HiRes`, else whole seconds.
6. The commit: HEAD when the batch started, or `unborn` before the first commit. A range batch names its range on byte-ceiling's dots: `REF...HEAD` under `--base REF`, `REF..HEAD` under `--against REF`.

A check run by name, a withheld check and a package-incomplete check write no row. A log that cannot be appended prints `commit-guards: run-log-unwritten=<path>` and the verdict stands. The file only grows; deleting it starts a new log.
