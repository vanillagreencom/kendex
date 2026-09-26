# CLI output

The design system a converted verb draws with, in `src/ui/`. `ui::channel(json)` picks the rendering; `Channel::Json` answers through `ui::answer`. KEN-1724 holds the design.

| Rendering | When | Draws |
|---|---|---|
| Rich | a terminal on both streams, or `KENDEX_UI=pretty` | colour, glyphs, a blank line before each section, callout and summary, lines wrapped at the terminal width up to 100 columns (`COLUMNS` pins it) |
| Plain | a pipe, `KENDEX_UI=plain`, `NO_COLOR`, `TERM=dumb` | the script grammar: a line at column 0 opens a block, two spaces make detail, no colour, no wrapping, no chrome |
| JSON | the verb's `--json` | the serialized answer, no component |

| Token | Use | ANSI 16 | Truecolor (`COLORTERM=truecolor`) |
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
| `→` | from, to | `->` |
| `›` | current choice, folded block | `>` |
| `─` | rule | `-` |
| `·` | between choices | `\|` |

ASCII applies when `LC_ALL`, `LC_CTYPE` or `LANG`, first non-empty, names no UTF-8 locale.

| Component | Rich | Plain |
|---|---|---|
| `header(verb, target)` | `kendex <verb>` and the target, one line | nothing |
| `section(title, count, status)` | blank line, bold title in the status colour, muted count | `title:` |
| `row(status, label, value)` | glyph and label, the value under it | `  label — value` |
| `change(name, old, new, scope)` | `name  old → new  [scope]` | the same, uncoloured |
| `callout(what, why, choices)` | blank line, `!` and what, then why and the choices | `! what`, then why and the choices, indented |
| `choices(&[Choice])` | `[Enter] Set up · [s] Skip`, the recommended one bold | the same, uncoloured |
| `link(text, Target)` | OSC 8 hyperlink to a file or URL | the text |
| `table(headers, rows)` | columns sized to content, a rule under the header | the columns, no rule |
| `spinner(label, tick)`, `ui::Spinner` | one line on stderr, cleared when dropped | nothing |
| `progress(done, total, label)` | a 20-cell bar and the count | nothing |
| `summary(status, text)` | blank line, glyph and bold text: the run's last line | the text |
| `details(title, lines, folded)` | folded: the title and a line count | the title and every line |
| `note(text)` | muted text | the text |

Each component escapes the values it is handed; `ui::stdout` and `ui::stderr` print what it drew unchanged. Snapshot tests per component in both renderings sit in `src/ui/components/tests.rs`; `tests/presentation/design.rs` holds `NO_COLOR` output equal to a pipe's and an 80-column terminal to 80 cells. `tests/tapes/check.tape` records the pilot with vhs.

## cliclack

The framed verbs still draw through cliclack. Its `Theme` cannot render `choices`: `Select` lists one item per line inside the frame's gutter, and its key handling, which no theme method reaches, takes `h`, `j`, `k` and `l` for navigation and binds no other letter, so `[s] Skip` cannot be a key. A `callout` through its `Theme` is a string the theme composes whole, which the component already is. Prompts move to the components as their verbs convert, and the dependency goes with the last framed call.
