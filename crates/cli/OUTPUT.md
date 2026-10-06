# CLI output

The design system a converted verb draws with, in `src/ui/`. `ui::channel(json)` picks the rendering; `Channel::Json` answers through `ui::answer`. KEN-1724 holds the design.

One output is not drawn with the components: `check --quiet`, the session hook's bounded report, which is agent-facing text core spells (`report::render_plain`) and `ui::out` prints.

| Rendering | When | Draws |
|---|---|---|
| Rich | a terminal on both streams, or `KENDEX_UI=pretty`, unless `NO_COLOR` or `TERM=dumb` is set or a Windows console refuses escape sequences | colour, glyphs, a blank line before each section, callout and summary, lines wrapped at the terminal width up to 100 columns (`COLUMNS` pins it) |
| Plain | a pipe, `KENDEX_UI=plain`, `NO_COLOR`, `TERM=dumb`, a Windows console that refuses escape sequences | the script grammar: a line at column 0 opens a block, two spaces make detail, no colour, no wrapping, no chrome |
| JSON | the verb's `--json` | the serialized answer, no component |

| Token | Use | ANSI 16 | Truecolor (`COLORTERM=truecolor` or `24bit`) |
|---|---|---|---|
| `Accent` | the verb, a key, a recommended choice | blue | `--primary` |
| `Ok` | done | green | `--good` |
| `Warn` | needs a decision | yellow | `--warning` |
| `Danger` | failed or blocked | red | `--critical` |
| `Info` | a notice, a remedy, a link | cyan | `--info` |
| `Muted` | counts, targets, ages | bright black | `--muted-foreground` |
| `Emphasis` | weight | bold | bold |

Truecolor values are the `.dark` block of `ui/src/index.css`; `ui::tokens` tests derive them from it.

| Symbol | Meaning | ASCII |
|---|---|---|
| `✓` | done | `v` |
| `✗` | failed or blocked | `x` |
| `!` | needs a decision | `!` |
| `•` | notice | `*` |
| `◉` | a critical safety finding | `#` |
| `◐` | a high safety finding | `+` |
| `○` | a medium or low safety finding | `o` |
| `→` | from, to | `->` |
| `›` | current choice, folded block | `>` |
| `─` | rule | `-` |
| `·` | between choices | `\|` |

ASCII applies when `LC_ALL`, `LC_CTYPE` or `LANG`, first non-empty, names no UTF-8 locale.

| Component | Rich | Plain |
|---|---|---|
| `header(verb, target)` | `kendex <verb>` and the target | nothing |
| `section(title, count, status)` | blank line, bold title in the status colour, muted count | `title:` |
| `row(status, &[Span], Value)` | glyph and label, its commands never broken; under it the value's copy as a command, then its remark wrapped | `  label — copy remark` |
| `detail(status, &[Span])` | a line one level under its row: the status glyph and the text, or muted text without one | `    text` |
| `change(name, old, new, scope)` | `name  old → new  [scope]`, or the name over `old → new` and the scope on lines of their own where that does not fit | the same, uncoloured |
| `callout(what, why, choices)` | blank line, `!` and what, then why where there is one, and the choices | `! what`, then why and the choices, indented |
| `choices(&[Choice])` | `[Enter] Set up · [s] Skip`, indented two spaces, the Enter default bold, wrapped between buttons | the same on one line, uncoloured |
| `picked(label)` | `›` and the choice a key picked, under its buttons | the same, uncoloured |
| `link(text, Target)` | OSC 8 hyperlink to a file or URL, with visible text wrapped to width | the text, indented two spaces |
| `table(headers, rows)` | columns sized to content, reduced to fit the width, wrapped cells, a rule under the header | the columns, no rule |
| `spinner(label, tick)`, `ui::Spinner` | one line on stderr, cleared when dropped | nothing |
| `progress(done, total, label)` | a 20-cell bar and the count | nothing |
| `summary(status, text)` | blank line, glyph and bold text: the run's last line | the text |
| `details(title, lines, folded)` | folded: the title and a line count | the title indented two spaces, every line indented four |
| `note(&[Span])` | muted text, its commands never broken | the spans joined |

A `Choice` is a label and its `Key`: `Key::Enter`, the stated default, or `Key::Char`.

A `Status` is `Done`, `Failed`, `Decision` or `Notice`, or a safety finding's severity: `Critical` (danger), `High` (warn) or `Low` (muted, medium included).

A plan's report (`src/commands/attention.rs`) is drawn from these: a `conflicts` section, then a `safety` section, then a `notes` section, each item a `row` with its `detail` lines. `advisory::Listing` says how much it draws. `refresh`, `apply` and `add` draw `Attention`: only the packages with a finding or a rule that had nothing to read, each finding once with its site count, and no hook exclusion a declaration does not contradict. `refresh` alone closes on `details folded` where the compact drawing differs from the verbose one, and draws it all under `--verbose`; `apply` and `add` have no flag that draws more. `pin`, `adopt`, `fork` and the drift-hook install close on no ledger and draw `Every` package, clean ones included.

Rich wraps prose between words and never breaks a command: text a component takes as `Span::Command` (core marks the commands in a report line and its next step with `report::Sentence`), or a `Value`'s copy, starts a new line where it does not fit and is drawn whole, and the terminal wraps one wider than a line. Each component escapes the values it is handed; `ui::stdout` and `ui::stderr` print what it drew unchanged. Snapshot tests per component in both renderings sit in `src/ui/components/tests.rs`; `tests/presentation/design.rs` holds `NO_COLOR` output equal to a pipe's and a rich run at `COLUMNS=80` to 80 cells, commands aside. `tests/tapes/check.tape` records the pilot with vhs.

## Questions

A converted verb asks through `ui::choose`, in `src/ui/keys.rs`: it drops the keys that reached the terminal before the question, draws the `choices` under what the verb drew above, reads one key, and draws the `picked` choice. A key typed after the question is drawn answers it, an Enter included that follows a key leading straight to an instantly drawn question, such as the offer's `c` and the message question. Enter takes the one `Key::Enter` choice, and every question has exactly one; letters match either case; a key the question does not show is ignored. Escape, Ctrl-C and the end of input cancel with the interrupted error `ui::cancelled` recognises, and the run exits 130 having written nothing the question asked about. A read that fails otherwise ends the question with the terminal's error. `ui::typed` reads a line for a question whose answer is text, with the same cancel; it keeps what was typed after the key that led to it.

Keys are read raw where stderr is a terminal. Where only stdin is one, as in `2>&1 | tee log`, the answer is a typed line: its first character is the key, an empty line is Enter, a line starting with Escape cancels, and a line that picks nothing draws the choices again. Ctrl-C there is the terminal's signal, which ends the run. `ui::choose` refuses to wait on a pipe, and each caller settles a run with no terminal on stdin before it asks: the write consent of `ask_before_writing` refuses before its first write, naming `--yes`; the repository-effect disclosure asks nothing, leaves the effects unmade and names `--allow-repo-effects`, and the linked work tree's setup is skipped; the commit offer, which comes after the writes, asks nothing and prints one line naming `--commit`, `--push`, `--pull-request` and `--leave`, and the verb's writes and exit code stand; a package that holds that offer is set up without asking where the run's `--allow-repo-effects` and commit choice say so, per `docs/architecture/repo-effects.md` § Rules, so `kendex remove --commit --allow-repo-effects <name>` commits in a checkout nobody set up; `add` asks neither of its questions and keeps the scope's own tools and delivery.

`ui::consent` is the yes a write needs: a `callout` and `[y] yes · [Enter] no`. `commands::engine_common::ask_before_writing` asks it, and so do the repository-effect disclosure and the linked work tree's setup (`commands::repo_effects`), so one `refresh` or `apply` asks every consent the same way.

`add` asks which tools a package installs to and how it is delivered (`src/commands/harness_picker.rs`), each a `callout` over keyed `choices`. `--harness`, `--all-harnesses` and `--yes` skip both, and `--method` or `--copy` the delivery question. The tools are toggles: the tools on the machine come checked, a number checks or unchecks the tool it shows, `a` checks every one, and each toggle draws the buttons again. Enter installs to the checked set, which its button names; with nothing checked it says so and asks again. The delivery question takes `c` for a copy each, and Enter links every tool to one shared copy.

The commit offer (`src/commands/commit_offer/block.rs`) heads each block with a `callout`, says each thing under it as a `row`, and quotes another program's words as a bare `detail`, whole. Its questions and their keys:

| Question | Keys | Enter |
|---|---|---|
| The offer | `c` commit, `p` push, `r` pull request, each where the preconditions leave it | leave the files as diffs |
| A package holds the commit | `s` set it up here | leave the files as diffs |
| The message | `e` type a different one | use the offered message |
| After a refused commit | `a` the same message, `m` a different one, typed straight away, `?` show everything the commit check printed | leave the files as diffs |
| After a refused push | `r` push to a new branch and open a pull request | leave the commit where it is |

`tests/tapes/refresh.tape` and `tests/tapes/commit-offer.tape` record the consent and the offer.

## cliclack

The framed verbs still draw through cliclack. Its `Theme` cannot render `choices`: `Select` lists one item per line inside the frame's gutter, and its key handling, which no theme method reaches, takes `h`, `j`, `k` and `l` for navigation and binds no other letter, so `[s] Skip` cannot be a key. A `callout` through its `Theme` is a string the theme composes whole, which the component already is. Prompts move to the components as their verbs convert. Still drawn with the cliclack widget on a rich terminal: `ui::confirm`, the typed yes of `remove` and of `add` into a folder that is not a project yet (`commands::start_a_project_here`). The dependency goes with it and the framed verbs.

Report lines whose plain prefixes scripts read use `Style::report_row`, `report_detail` and `report_callout` from `src/ui/report.rs`. They retain that plain grammar and delegate rich drawing to `row`, `detail` and `callout`; `report_warning(text)` is the one spelling of a warning's status and its plain `warning: ` key, for the verbs that build lines and for `ui::report::warning` alike. Rows and detail take spans: paths and executable commands stay whole; prose wraps. Shared reports emit through `ui::report::print`, which feeds the plain grammar into an active legacy frame and uses the components directly otherwise. The plan and disclosure snapshots live beside `commands/engine_common.rs` and `commands/repo_effects/disclose.rs`; `tests/presentation/design.rs` checks the writing verbs' plain overrides, wrapping and refusal before writes.

The inspection verbs `list`, `show`, `updates`, `verify` and `diff` are converted: each draws a `header`, then its report from the components and from the report components in `src/ui/report.rs`, which own every fork between a plain grammar scripts read and its rich drawing, so no verb reads the rendering itself. `report_table(title, headers, rows, PlainColumns)` is a `section` and a `table` rich and the headerless columns plain, `Padded` to the widest cell for `list` and `Joined` as written for `show --files`, whose plain line is `path  N bytes`; `report_link` is a `link` rich and its text plain; `report_change(scope, name, old, new, notes)` is a `change` and a marked `detail` per note rich and the one line `scope  name  old -> new  [notes]` plain; `report_verdict(label, problem)` is a `row` with the reason as `detail` rich and `✓ label` or `✗ label: problem` plain; `report_group` is a row that plain sets off with a blank line; `report_verbatim(status, text)` is the one door for another program's line, a diff line or a parser's diagram, drawn as a `detail` that keeps every space; `report_totals` is a `section` opening the group and a `summary` closing it rich, and plain the totals once, first. `diff` hunks and the body of a refusal `Style::refusal` draws go through `report_verbatim`, whose `Span::Verbatim` keeps every space and breaks by cells alone. `show --file` and `show --readme` print their payload through `ui::payload` in every rendering. `verify --json`, its exit meanings and `check --quiet` are untouched. The rich and plain snapshots sit beside each verb in `src/commands/list/tests.rs`, `show/tests.rs`, `updates_cmd/tests.rs` and `diff_cmd/tests.rs`, and the verdict rows `verify` draws in `src/ui/report.rs`; `tests/presentation/design.rs` runs each verb under `NO_COLOR`, `TERM=dumb`, a pipe and an 80-column terminal, and holds the `show --file` bytes equal across plain, rich, `NO_COLOR`, `TERM=dumb`, `COLUMNS=80` and a pipe.

Plan operations use `Style::plan_row` for both the initial report and additions after settlement. It maps core's `PlannedOp::description_parts` to prose and command spans, keeping each landed path whole. Core derives the unchanged flat `line` from those same parts for approval comparison and consumers that need one string. `tests/instruction_shims_cli.rs` exercises the shipped shim producer in a project path with spaces.

## Help

`src/help.rs` builds the command used by dispatch and applies the help layout to its children. The command description precedes usage. Clap supplies the Commands, Arguments and Options groups through the `{all-args}` template. Clap can copy a flattened argument struct's documentation into the root description; the command builder sets the root description after flattening. Internal contracts belong in this reference or the author instructions, outside help descriptions. `src/help/tests.rs` discovers the command tree and compares every command with its snapshot under `tests/snapshots/help/`, including hidden commands.

The commit flags form one mutually exclusive group. They apply only to commands that offer a commit. `CommitFlags::from_matches` reads the selected command's matches, including the bare install form. The bare source argument dispatches to `add` with its same flags. The author instructions define the check exit codes and the session hook's output exception.

The support commands keep stdout and stderr separate. Init writes created paths to stdout. Login writes instructions to stderr and never prints its private device code. Report keeps submission results on stdout and dry-run fields on stderr. Its dry-run field names, ordering and quoted GitHub CLI arguments are the plain output protocol; the serialized issue body and routing marker are payloads, not terminal text.
