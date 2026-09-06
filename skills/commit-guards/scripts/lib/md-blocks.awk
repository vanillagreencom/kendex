# md-blocks.awk — the one reading of a markdown file's block structure that
# md-format, md-reflow and md-refs share. POSIX awk, one file per run.
#
#   -v mode=check    "V<TAB>line<TAB>rule" per format violation
#   -v mode=reflow   the file rewritten to the format, on stdout
#   -v mode=lines    "T<TAB>line<TAB>content" per judged line, "X..." per
#                    HTML block line, "H<TAB>line<TAB>text" per heading;
#                    content has the blockquote prefix stripped
#
# An unterminated fence, front matter, HTML comment or prompt-section block
# is "R<TAB>line<TAB>reason" and exit 2 in every mode: what follows cannot
# be judged. A CRLF line is refused the same way, except in check mode,
# where it is the file's one violation. The grammar and the rules are
# stated once, in CHECKS.md § md-format and § md-reflow; this file is that
# statement as a state machine, and the line-shape predicates it asks
# (heading, thematic break, tag, delimiter row, blockquote prefix) are
# md-shapes.awk's, loaded as the first `-f` program beside it.

function out(s) { if (mode == "reflow") print s }

function emit(kind, text) { if (mode == "lines") printf "%s\t%d\t%s\n", kind, FNR, text }

function flush() {
  if (have_buf) {
    out(buf)
    have_buf = 0
    buf = ""
  }
}

function violation(rule) { if (mode == "check") printf "V\t%d\t%s\n", FNR, rule }

# The blank line the format requires after a heading or a fence closer,
# whatever follows; anything else just ends the open paragraph.
function close_block() {
  if (prev == "heading") separate("a heading not followed by a blank line")
  else if (prev == "fence") separate("a fence not followed by a blank line")
  else flush()
}

function refuse(line, reason) {
  printf "R\t%d\t%s\n", line, reason
  refused = 1
  exit 2
}

# A separating blank line the format requires before the current line, in
# the current container; check mode names the rule instead.
function separate(rule) {
  violation(rule)
  if (mode == "reflow") {
    flush()
    out(rtrim(PREFIX))
  }
}

# The innermost open list item's content indent, kept as a stack so a
# nested list hands back to its parent when it ends.
function list_pop_to(ind) {
  while (nstack > 0 && stack_cind[nstack] > ind) nstack--
  list_indent = (nstack > 0) ? stack_cind[nstack] : 0
}

function list_push(ind, cind) {
  nstack++
  stack_cind[nstack] = cind
  list_indent = cind
}

BEGIN {
  if (mode != "check" && mode != "reflow" && mode != "lines") {
    printf "md-blocks.awk: mode must be check, reflow or lines (got '%s')\n", mode > "/dev/stderr"
    exit 2
  }
  region = ""
  prev = "start"
  prev_depth = 0
  buf = ""
  have_buf = 0
  nstack = 0
  list_indent = 0
  refused = 0
  stopped = 0
}

stopped { next }

{
  raw = $0
  if (raw ~ /\r$/) {
    if (mode == "check") {
      violation("a CRLF line ending; the format is LF, and the file is not judged past this line")
      stopped = 1
      next
    }
    refuse(FNR, "a CRLF line ending")
  }

  # Front matter: both delimiters at column zero, on the raw line.
  if (FNR == 1 && raw ~ /^---[ \t]*$/) {
    region = "front"
    open_line = FNR
    out(raw)
    next
  }
  if (region == "front") {
    out(raw)
    if (raw ~ /^---[ \t]*$/) {
      region = ""
      prev = "blank"
      prev_depth = 0
    }
    next
  }

  if (region == "fence") {
    content = strip_bq(raw, fence_depth)
    if (DEPTH < fence_depth) {
      # The quote holding the fence ended, and the fence with it.
      region = ""
      prev = "blank"
    } else {
      out(raw)
      lead_cols(content)
      n = 0
      while (substr(BODY, n + 1, 1) == fence_char) n++
      if (n >= fence_len && substr(BODY, n + 1) ~ /^[ \t]*$/) {
        region = ""
        prev = "fence"
        prev_depth = fence_depth
      }
      next
    }
  }

  if (region == "html") {
    content = strip_bq(raw, html_depth)
    if (DEPTH < html_depth) {
      region = ""
      prev = "blank"
    } else {
      out(raw)
      emit("X", content)
      if (html_end == "") {
        if (content ~ /^[ \t]*$/) {
          region = ""
          prev = "blank"
          prev_depth = DEPTH
        }
      } else if (index(content, html_end) > 0) {
        region = ""
        prev = "html"
      }
      next
    }
  }

  content = strip_bq(raw, -1)
  depth = DEPTH
  ind = lead_cols(content)
  body = BODY

  if (body == "") {
    flush()
    out(raw)
    emit("T", content)
    prev = "blank"
    prev_depth = depth
    next
  }

  # A paragraph shape, for the lazy-continuation test below.
  is_marker = match(body, /^([-*+]|[0-9]+[.)])([ \t]+|$)/) && !is_thematic(body)
  is_plain = !is_marker && !is_atx(body) && body !~ /^(```|~~~)/ && substr(body, 1, 1) != "|" && substr(body, 1, 1) != "<" && !is_thematic(body)

  lazy = 0
  if (depth != prev_depth) {
    if (depth < prev_depth && prev == "para" && is_plain) {
      lazy = 1
    } else if (prev != "start" && prev != "blank") {
      # A depth change is a boundary. The blank line the format wants on
      # either side of a heading, or after a fence closer, sits at the
      # shallower depth, where it ends neither quote.
      full = PREFIX
      if (depth > prev_depth) strip_bq(raw, prev_depth)
      bound_prefix = PREFIX
      close_block()
      PREFIX = full
      prev = "bound"
    }
  }

  if (!is_marker) list_pop_to(ind)

  if ((prev == "blank" || prev == "start" || prev == "code" || prev == "bound") && ind >= list_indent + 4) {
    flush()
    out(raw)
    prev = "code"
    prev_depth = depth
    next
  }

  if (ind < list_indent + 4 && body ~ /^(```|~~~)/) {
    fchar = substr(body, 1, 1)
    flen = 0
    while (substr(body, flen + 1, 1) == fchar) flen++
    if (fchar == "~" || index(substr(body, flen + 1), "`") == 0) {
      if (prev == "para" || prev == "item") separate("a fence directly under a paragraph or list line; put a blank line before it")
      else close_block()
      out(raw)
      region = "fence"
      open_line = FNR
      fence_char = fchar
      fence_len = flen
      fence_depth = depth
      prev_depth = depth
      next
    }
  }

  if (ind < list_indent + 4 && is_atx(body)) {
    if (prev == "bound") {
      full = PREFIX
      PREFIX = bound_prefix
      separate("a heading not preceded by a blank line")
      PREFIX = full
    }
    else if (!(prev == "blank" || prev == "start" || prev == "html")) separate("a heading not preceded by a blank line")
    else flush()
    out(raw)
    text = body
    sub(/^#+[ \t]*/, "", text)
    sub(/[ \t]+#+[ \t]*$/, "", text)
    emit("H", rtrim(text))
    prev = "heading"
    prev_depth = depth
    next
  }

  if (prev == "para" && !lazy && para_lines == 1 && ind < list_indent + 4 && index(para_body, "|") > 0 && is_delim_row(body)) {
    # GFM: a one-line paragraph holding a pipe, over a delimiter row, is a
    # table's header row, whether or not either line begins with a pipe.
    have_buf = 0
    buf = ""
    out(para_raw)
    out(raw)
    emit("T", content)
    prev = "table"
    prev_depth = depth
    next
  }

  if (prev == "para" && !lazy && ind < list_indent + 4 && (body ~ /^=+[ \t]*$/ || body ~ /^-+[ \t]*$/)) {
    # Setext underline: the paragraph above it is the heading.
    flush()
    out(raw)
    emit("H", setext_text)
    prev = "heading"
    prev_depth = depth
    next
  }

  if (is_thematic(body)) {
    close_block()
    out(raw)
    emit("T", content)
    prev = "break"
    prev_depth = depth
    next
  }

  # A pipe-first line opens a table; an open table runs to the next blank
  # line (GFM), so every line until then is a row whatever it holds.
  if (substr(body, 1, 1) == "|" || prev == "table") {
    close_block()
    out(raw)
    emit("T", content)
    prev = "table"
    prev_depth = depth
    next
  }

  if (ind < list_indent + 4 && substr(body, 1, 1) == "<") {
    term = "?"
    rest = ""
    if (substr(body, 1, 4) == "<!--") { term = "-->"; rest = substr(body, 5) }
    else if (substr(body, 1, 2) == "<?") { term = "?>"; rest = substr(body, 3) }
    else if (substr(body, 1, 9) == "<![CDATA[") { term = "]]>"; rest = substr(body, 10) }
    else if (substr(body, 1, 2) == "<!" && substr(body, 3, 1) ~ /[A-Za-z]/) { term = ">"; rest = substr(body, 3) }
    else if (is_block_tag(body)) term = ""
    else if (prev != "para" && prev != "item" && is_lone_tag(body)) {
      term = ""
      # No HTML element's name holds `_`: such a tag is a prompt section
      # (`<output_format>`), and its block runs to its closing tag, blank
      # lines included, because its lines are a template, not prose.
      match(body, /^<[A-Za-z][A-Za-z0-9_-]*/)
      if (index(substr(body, 1, RLENGTH), "_") > 0) term = "</" substr(body, 2, RLENGTH - 1) ">"
    }
    if (term != "?") {
      close_block()
      out(raw)
      emit("X", content)
      if (term == "" || index(rest, term) == 0) {
        region = "html"
        open_line = FNR
        html_end = term
        html_kind = (substr(term, 1, 2) == "</") ? term : "HTML block"
        html_depth = depth
      }
      prev = "html"
      prev_depth = depth
      next
    }
  }

  if (ind < list_indent + 4 && body ~ /^\[[^]]+\]:[ \t]*[^ \t]/) {
    close_block()
    out(raw)
    emit("T", content)
    prev = "def"
    prev_depth = depth
    next
  }

  if (is_marker) {
    mlen = RLENGTH
    while (substr(body, mlen, 1) ~ /[ \t]/) mlen--
    ws = RLENGTH - mlen
    cind = (ws == 0 || ws >= 5) ? ind + mlen + 1 : ind + RLENGTH
    list_pop_to(ind)
    list_push(ind, cind)
    if (prev == "para") separate("a list item directly under a paragraph line; put a blank line before the list")
    else close_block()
    if (raw ~ /  $/) violation("a trailing-double-space line break; join the lines instead")
    emit("T", content)
    buf = rtrim(raw)
    have_buf = 1
    prev = "item"
    prev_depth = depth
    next
  }

  # A paragraph line.
  if (prev == "para" || prev == "item" || lazy) {
    violation(prev == "item" ? "a list item continued on the next line; put the whole item on one line" : "a paragraph hard-wrapped over lines; put the whole paragraph on one line")
    buf = buf " " rtrim(body)
    if (prev == "para") setext_text = setext_text " " rtrim(body)
    para_lines++
  } else {
    close_block()
    buf = rtrim(raw)
    have_buf = 1
    setext_text = rtrim(body)
    para_raw = raw
    para_body = body
    para_lines = 1
    prev = "para"
    prev_depth = depth
  }
  if (raw ~ /  $/) violation("a trailing-double-space line break; join the lines instead")
  emit("T", content)
  next
}

END {
  if (refused || stopped) exit (refused ? 2 : 0)
  if (region == "fence") refuse(open_line, "an unterminated fence")
  if (region == "front") refuse(open_line, "unterminated front matter")
  if (region == "html" && html_end != "") refuse(open_line, (html_kind == "HTML block") ? "an unterminated HTML block" : "a block with no closing " html_kind)
  flush()
}
