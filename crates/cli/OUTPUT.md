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
| `change(name, old, new, scope)` | `name  old → new  [scope]` | the same, uncoloured |
| `callout(what, why, choices)` | blank line, `!` and what, then why and the choices | `! what`, then why and the choices, indented |
| `choices(&[Choice])` | `[Enter] Set up · [s] Skip`, the recommended one bold | the same, uncoloured |
| `link(text, Target)` | OSC 8 hyperlink to a file or URL | the text, indented two spaces |
| `table(headers, rows)` | columns sized to content, a rule under the header | the columns, no rule |
| `spinner(label, tick)`, `ui::Spinner` | one line on stderr, cleared when dropped | nothing |
| `progress(done, total, label)` | a 20-cell bar and the count | nothing |
| `summary(status, text)` | blank line, glyph and bold text: the run's last line | the text |
| `details(title, lines, folded)` | folded: the title and a line count | the title indented two spaces, every line indented four |
| `note(&[Span])` | muted text, its commands never broken | the spans joined |

A `Status` is `Done`, `Failed`, `Decision` or `Notice`, or a safety finding's severity: `Critical` (danger), `High` (warn) or `Low` (muted, medium included).

A plan's report (`src/commands/attention.rs`) is drawn from these: a `conflicts` section, then a `safety` section of the packages with a finding or an unread rule, then a `notes` section, each item a `row` with its `detail` lines. A compact run leaves out clean packages and the hook exclusions no declaration contradicts, and the closing ledger counts them behind `--verbose`.

Rich wraps prose between words and never breaks a command: text a component takes as `Span::Command` (core marks the commands in a report line and its next step with `report::Sentence`), or a `Value`'s copy, starts a new line where it does not fit and is drawn whole, and the terminal wraps one wider than a line. Each component escapes the values it is handed; `ui::stdout` and `ui::stderr` print what it drew unchanged. Snapshot tests per component in both renderings sit in `src/ui/components/tests.rs`; `tests/presentation/design.rs` holds `NO_COLOR` output equal to a pipe's and a rich run at `COLUMNS=80` to 80 cells, commands aside. `tests/tapes/check.tape` records the pilot with vhs.

## cliclack

The framed verbs still draw through cliclack. Its `Theme` cannot render `choices`: `Select` lists one item per line inside the frame's gutter, and its key handling, which no theme method reaches, takes `h`, `j`, `k` and `l` for navigation and binds no other letter, so `[s] Skip` cannot be a key. A `callout` through its `Theme` is a string the theme composes whole, which the component already is. Prompts move to the components as their verbs convert, and the dependency goes with the last framed call.
