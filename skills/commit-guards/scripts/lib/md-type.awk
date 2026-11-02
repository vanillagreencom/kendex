# md-type.awk — md-type's readings: docs-writing's route table and numbered
# section lists as data, an example's document, and the structure of a
# judged file. POSIX awk, loaded after md-shapes.awk. Parsed only by
# scripts/md-type; every record is tab-separated with a one-letter kind.
#
# The rules, order and judge modes read md-blocks.awk's lines stream, the
# one reading of a file's block structure, so a fence or front matter is
# skipped by the grammar md-reflow and md-refs use.
#
#   -v mode=rules    SKILL.md's lines stream -> "R line type globs reference
#                    example checks" per route row, "-" for an empty cell;
#                    "U detector line" when the table breaks the contract
#                    (one Path|Section|Example|Shape table, four cells a row,
#                    known shape names)
#   -v mode=order    a reference's lines stream -> "O index line names" per
#                    item of its first numbered list; names are lowercased,
#                    joined by "|": the item's name, and each side of an
#                    "X or Y" name
#   -v mode=example  an example file -> its document's lines: the content of
#                    its first `markdown` fence before any thematic break,
#                    else the file up to its first thematic break, front
#                    matter excluded. A raw read, because the lines stream
#                    emits no fence content.
#   -v mode=judge    two files, the judged file then md-blocks' lines stream
#                    for it -> "F finding line rule-line section" per finding
#                    (rule-line 0 where the route row is the rule), then
#                    "W count" of the stream's words. -v checks names the
#                    shapes to judge and -v order_file the order records. The
#                    judged file is read only for a heading's level, which
#                    the stream's H record does not carry.
#
# The judge reads structure only: heading levels and order, the content
# between the title and the first H2, and a table's header cells. It matches
# no prose.

BEGIN {
  FS = "\n"
  if (mode != "rules" && mode != "order" && mode != "example" && mode != "judge") {
    printf "md-type: mode=%s\n  Expected rules, order, example or judge.\n", mode > "/dev/stderr"
    exit 2
  }
  # Header cells naming a value a table hands out: defaults, budgets and
  # limits. Lowercased; a README or architecture doc points to the code that
  # owns these instead (docs-writing's value-table shape).
  split("default defaults budget budgets limit limits ceiling ceilings threshold thresholds", vt, " ")
  for (i in vt) VALUE_HEADERS[vt[i]] = 1
  SHAPES["order"] = 1
  SHAPES["value-table"] = 1
  in_front = 0
  headers = 0
  in_table = 0
  words = 0
  ndoc = 0
  if (mode == "judge") {
    nitems = 0
    while ((status = getline rec < order_file) > 0) {
      split(rec, of, "\t")
      nitems++
      item_line[nitems] = of[3]
      item_names[nitems] = of[4]
    }
    if (status < 0) {
      printf "md-type: order-read=%s\n", order_file > "/dev/stderr"
      exit 2
    }
    close(order_file)
    judge_order = index(" " checks " ", " order ") > 0
    judge_values = index(" " checks " ", " value-table ") > 0
  }
}

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function dash(s) { return (s == "") ? "-" : s }

# A pipe row's cells, outer pipes optional. Sets NCELLS and CELL[1..n].
function cells(s,   n, i, parts) {
  s = trim(s)
  sub(/^\|/, "", s)
  sub(/\|$/, "", s)
  n = split(s, parts, "|")
  for (i = 1; i <= n; i++) CELL[i] = trim(parts[i])
  NCELLS = n
}

# Every code span's text in S, space-joined.
function spans(s,   out) {
  out = ""
  while (match(s, /`[^`]+`/)) {
    out = out (out == "" ? "" : " ") substr(s, RSTART + 1, RLENGTH - 2)
    s = substr(s, RSTART + RLENGTH)
  }
  return out
}

function link_target(s) {
  if (!match(s, /\]\([^) ]+\)/)) return ""
  return substr(s, RSTART + 2, RLENGTH - 3)
}

function count_words(s,   n, parts) {
  n = split(s, parts, /[ \t]+/)
  if (n > 0 && parts[1] == "") n--
  if (n > 0 && parts[n] == "" && s ~ /[ \t]$/) n--
  return n
}

# One lines-stream record: "kind TAB line TAB content", content holding tabs
# of its own. Sets KIND, LINE and CONTENT.
function record(   rest, t) {
  KIND = substr($0, 1, 1)
  rest = substr($0, 3)
  t = index(rest, "\t")
  LINE = (t > 0) ? substr(rest, 1, t - 1) + 0 : rest + 0
  CONTENT = (t > 0) ? substr(rest, t + 1) : ""
}

mode == "rules" {
  record()
  if (KIND != "T") { in_table = 0; next }
  if (in_table) {
    if (CONTENT !~ /^[ \t]*\|/) { in_table = 0; next }
    if (is_delim_row(trim(CONTENT))) next
    cells(CONTENT)
    if (NCELLS != 4) { printf "U\tcells\t%d\n", LINE; next }
    globs = spans(CELL[1])
    reference = link_target(CELL[2])
    if (reference != "") {
      type = reference
      sub(/^.*\//, "", type)
      sub(/\.md$/, "", type)
    } else {
      type = tolower(CELL[2])
      sub(/^§[ \t]*/, "", type)
      gsub(/[^a-z0-9]+/, "-", type)
      gsub(/^-+|-+$/, "", type)
    }
    if (type == "") { printf "U\ttype\t%d\n", LINE; next }
    checks = spans(CELL[4])
    if (checks == "") {
      if (tolower(CELL[4]) != "none") { printf "U\tshape\t%d\n", LINE; next }
    } else {
      n = split(checks, names, " ")
      for (i = 1; i <= n; i++) if (!(names[i] in SHAPES)) { printf "U\tshape\t%d\n", LINE; next }
    }
    # md-type reads these with a tab IFS, which merges adjacent tabs: an
    # empty cell is written "-" so no field shifts into its neighbour.
    printf "R\t%d\t%s\t%s\t%s\t%s\t%s\n", LINE, type, dash(globs), dash(reference), dash(link_target(CELL[3])), dash(checks)
    next
  }
  cells(CONTENT)
  if (CONTENT ~ /^[ \t]*\|/ && NCELLS == 4 && CELL[1] == "Path" && CELL[2] == "Section" && CELL[3] == "Example" && CELL[4] == "Shape") {
    headers++
    in_table = 1
  }
  next
}

mode == "order" {
  record()
  if (done) next
  if (KIND == "T" && match(CONTENT, /^[0-9]+\.[ \t]+/)) {
    name = substr(CONTENT, RLENGTH + 1)
    if (match(name, /[:,.]/)) name = substr(name, 1, RSTART - 1)
    name = tolower(trim(name))
    # Not "alts", the judge's array: mawk refuses one name used both ways.
    joined = name
    if (index(name, " or ") > 0) {
      n = split(name, sides, / or /)
      for (i = 1; i <= n; i++) joined = joined "|" trim(sides[i])
    }
    printf "O\t%d\t%d\t%s\n", ++items, LINE, joined
    next
  }
  if (items > 0 && !(KIND == "T" && CONTENT ~ /^[ \t]*$/)) done = 1
  next
}

# The length of BODY's leading run of CH.
function run_of(ch,   n) {
  n = 0
  while (substr(BODY, n + 1, 1) == ch) n++
  return n
}

function closes(ch, len,   n) {
  n = run_of(ch)
  return n >= len && substr(BODY, n + 1) ~ /^[ \t]*$/
}

mode == "example" {
  if (stop) next
  if (FNR == 1 && $0 ~ /^---[ \t]*$/) { in_front = 1; next }
  if (in_front) { if ($0 ~ /^---[ \t]*$/) in_front = 0; next }
  lead_cols($0)
  if (inner) {
    if (closes(fence_char, fence_len)) { stop = 1; next }
    doc[++ndoc] = $0
    next
  }
  if (code) {
    if (closes(fence_char, fence_len)) code = 0
    doc[++ndoc] = $0
    next
  }
  if (BODY ~ /^(```|~~~)/) {
    fence_char = substr(BODY, 1, 1)
    fence_len = run_of(fence_char)
    if (substr(BODY, fence_len + 1) ~ /^[ \t]*markdown[ \t]*$/) {
      # The document itself: what the example led into it is not part of it.
      inner = 1
      ndoc = 0
      next
    }
    code = 1
    doc[++ndoc] = $0
    next
  }
  if (is_thematic(BODY)) { stop = 1; next }
  doc[++ndoc] = $0
  next
}

mode == "judge" && NR == FNR { raw[FNR] = $0; next }

mode == "judge" {
  record()
  if (KIND == "T" || KIND == "X") words += count_words(CONTENT)
  if (KIND == "H") {
    lead_cols(strip_bq(raw[LINE], -1))
    level = 0
    start = LINE
    if (is_atx(BODY)) {
      while (substr(BODY, level + 1, 1) == "#") level++
      words += count_words(CONTENT)
    } else {
      level = (substr(BODY, 1, 1) == "=") ? 1 : 2
      # A Setext heading's text arrived as T records before its underline:
      # those lines are the heading, never content beside it.
      if (run_start) start = run_start
    }
    while (ncontent > 0 && content_at[ncontent] >= start) ncontent--
    section = CONTENT
    # The title is the file's first heading, whatever its level: a README
    # titled with an H2 still has its description under that title.
    if (!title_line) title_line = LINE
    if (level == 1 && !h1_line) h1_line = LINE
    if (level == 2 && LINE != title_line) {
      if (!h2_line) { h2_line = LINE; h2_start = start }
      nh2++
      h2_at[nh2] = LINE
      h2_text[nh2] = CONTENT
    }
    prev_t = 0
    run_start = 0
    next
  }
  lead_cols(CONTENT)
  body = BODY
  if (KIND == "T" && body != "") { if (!run_start) run_start = LINE }
  else run_start = 0
  if (body != "") { ncontent++; content_at[ncontent] = LINE }
  if (KIND != "T") { prev_t = 0; next }
  if (prev_t == LINE - 1 && index(prev_body, "|") > 0 && is_delim_row(body)) {
    cells(prev_body)
    for (i = 1; i <= NCELLS; i++) {
      cell = tolower(CELL[i])
      gsub(/[*_`]/, "", cell)
      if (cell in VALUE_HEADERS) {
        nvalue++
        value_at[nvalue] = prev_t
        value_section[nvalue] = prev_section
        break
      }
    }
  }
  prev_t = LINE
  prev_body = body
  prev_section = (section == "") ? "top" : section
  next
}

END {
  if (mode == "rules") {
    if (headers != 1) printf "U\troute-table\t%d\n", headers
    exit 0
  }
  if (mode == "example") {
    for (i = 1; i <= ndoc; i++) print doc[i]
    exit 0
  }
  if (mode != "judge") exit 0
  if (judge_values) for (i = 1; i <= nvalue; i++) printf "F\tvalue-table\t%d\t0\t%s\n", value_at[i], value_section[i]
  if (judge_order && nitems > 0) {
    # The description is content after the title and before the first
    # section; content above the title is not under it.
    lead = 0
    for (k = 1; k <= ncontent && !lead; k++)
      if (content_at[k] > title_line && (!h2_start || content_at[k] < h2_start)) lead = 1
    if (!lead) printf "F\tdescription-missing\t%d\t%d\ttop\n", (h2_line ? h2_line : (h1_line ? h1_line : 1)), item_line[1]
    highest = 0
    for (h = 1; h <= nh2; h++) {
      name = tolower(trim(h2_text[h]))
      matched = 0
      for (k = 1; k <= nitems && !matched; k++) {
        n = split(item_names[k], alts, "|")
        for (a = 1; a <= n; a++) if (alts[a] == name) { matched = k; break }
      }
      if (!matched) continue
      if (matched < highest) printf "F\tsection-order\t%d\t%d\t%s\n", h2_at[h], item_line[matched], h2_text[h]
      else highest = matched
    }
  }
  printf "W\t%d\n", words
}
