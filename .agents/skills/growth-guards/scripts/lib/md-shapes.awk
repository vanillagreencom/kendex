# md-shapes.awk — the line-shape predicates md-blocks.awk asks: how far a
# line is indented, which blockquote prefix it carries, and whether it is a
# heading, a thematic break, an HTML tag or a table's delimiter row. Loaded
# as the first `-f` program beside md-blocks.awk, never alone; POSIX awk.
# The grammar each predicate spells is CHECKS.md § md-format's.

BEGIN {
  # CommonMark's type-6 tag names, plus `source`, which GitHub suppresses too.
  BLOCK_TAGS = "address article aside base basefont blockquote body caption center col colgroup dd details dialog dir div dl dt fieldset figcaption figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header hr html iframe legend li link main menu menuitem nav noframes ol optgroup option p param search section source summary table tbody td tfoot th thead title tr track ul"
}

function tab_stop(col) { return col + 4 - (col % 4) }

# Sets BODY to S past its leading whitespace; returns the columns skipped.
function lead_cols(s,   i, c, n) {
  n = 0
  i = 1
  while (1) {
    c = substr(s, i, 1)
    if (c == " ") n++
    else if (c == "\t") n = tab_stop(n)
    else break
    i++
  }
  BODY = substr(s, i)
  return n
}

# Strips up to MAX blockquote markers (-1 for all) from S. Sets DEPTH to the
# count stripped and PREFIX to the text taken off, and returns the rest.
function strip_bq(s, max,   n) {
  DEPTH = 0
  PREFIX = ""
  while (max < 0 || DEPTH < max) {
    n = 0
    while (n < 3 && substr(s, n + 1, 1) == " ") n++
    if (substr(s, n + 1, 1) != ">") break
    PREFIX = PREFIX substr(s, 1, n + 1)
    s = substr(s, n + 2)
    if (substr(s, 1, 1) == " " || substr(s, 1, 1) == "\t") {
      PREFIX = PREFIX substr(s, 1, 1)
      s = substr(s, 2)
    }
    DEPTH++
  }
  return s
}

function rtrim(s) { sub(/[ \t]+$/, "", s); return s }

function is_thematic(s) {
  return s ~ /^-[ \t]*-[ \t]*-([ \t]*-)*[ \t]*$/ \
    || s ~ /^_[ \t]*_[ \t]*_([ \t]*_)*[ \t]*$/ \
    || s ~ /^\*[ \t]*\*[ \t]*\*([ \t]*\*)*[ \t]*$/
}

# ATX heading: one to six `#`, then a space, a tab, or the end of the line.
function is_atx(s,   n) {
  n = 0
  while (substr(s, n + 1, 1) == "#") n++
  if (n < 1 || n > 6) return 0
  return substr(s, n + 1, 1) ~ /^[ \t]?$/
}

# A type-6 block tag, open or closing, with or without attributes.
function is_block_tag(s,   rest, tag) {
  if (substr(s, 1, 1) != "<") return 0
  rest = substr(s, 2)
  if (substr(rest, 1, 1) == "/") rest = substr(rest, 2)
  if (!match(rest, /^[A-Za-z][A-Za-z0-9-]*/)) return 0
  tag = tolower(substr(rest, RSTART, RLENGTH))
  rest = substr(rest, RLENGTH + 1)
  if (rest != "" && rest !~ /^[ \t>]/ && rest !~ /^\/>/) return 0
  return index(" " BLOCK_TAGS " ", " " tag " ") > 0
}

# A complete open or closing tag alone on its line (CommonMark type 7). The
# tag name takes `_` beyond CommonMark's grammar: the prompt-section tags
# (`<output_format>`, `<delegation_format>`) wrap blocks whose lines are
# not prose.
function is_lone_tag(s) {
  if (s ~ /^<\/[A-Za-z][A-Za-z0-9_-]*[ \t]*>[ \t]*$/) return 1
  return s ~ /^<[A-Za-z][A-Za-z0-9_-]*([ \t]+[A-Za-z_:][A-Za-z0-9_.:-]*([ \t]*=[ \t]*([^ \t"'=<>`]+|'[^']*'|"[^"]*"))?)*[ \t]*\/?>[ \t]*$/
}

# GFM's delimiter row: cells of `-` with an optional `:` at either end,
# separated by `|`, the outer pipes optional; it must hold a pipe, or it is
# a setext underline or a thematic break.
function is_delim_row(s) {
  return index(s, "|") > 0 && s ~ /^\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/
}
