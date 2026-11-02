# md-type.awk — md-type's readings: docs-writing's route table and numbered
# section lists as data, an example's document words, and the structure of a
# judged file. POSIX awk, loaded after md-shapes.awk. Parsed only by
# scripts/md-type; every record is tab-separated with a one-letter kind.
#
#   -v mode=rules    SKILL.md -> "R line type globs reference example checks"
#                    per route row; "U detector line" when the table breaks
#                    the contract (one Path|Section|Example|Shape table,
#                    four cells a row, known shape names)
#   -v mode=order    a reference -> "O index line names" per item of its
#                    first numbered list; names are lowercased, joined by
#                    "|": the item's name, and each side of an "X or Y" name
#   -v mode=words    a file -> "W count": whitespace tokens past front matter
#   -v mode=example  an example -> "W count" of its document: a leading
#                    four-backtick markdown fence's content, else the file up
#                    to its first thematic break
#   -v mode=judge    two files, the judged file then md-blocks' lines stream
#                    for it -> "F finding line rule-line section" per finding
#                    (rule-line 0 where the route row is the rule), then
#                    "W count". -v checks names the shapes to judge and
#                    -v order_file the order records.
#
# The judge reads structure only: heading levels and order, the lead before
# the first H2 after the title, and a table's header cells. It matches no
# prose.

BEGIN {
  FS = "\n"
  if (mode != "rules" && mode != "order" && mode != "words" && mode != "example" && mode != "judge") {
    printf "md-type: mode=%s\n  Expected rules, order, words, example or judge.\n", mode > "/dev/stderr"
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
  in_fence = 0
  headers = 0
  in_table = 0
  words = 0
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

# Front matter and fences, for the readers that scan raw lines. Returns 1
# when the line is front matter or a fence line.
function skip_block(raw,   body, run) {
  if (FNR == 1 && raw ~ /^---[ \t]*$/) { in_front = 1; return 1 }
  if (in_front) {
    if (raw ~ /^---[ \t]*$/) in_front = 0
    return 1
  }
  lead_cols(raw)
  body = BODY
  if (in_fence) {
    run = 0
    while (substr(body, run + 1, 1) == fence_char) run++
    if (run >= fence_len && substr(body, run + 1) ~ /^[ \t]*$/) in_fence = 0
    return 1
  }
  if (body ~ /^(```|~~~)/) {
    fence_char = substr(body, 1, 1)
    fence_len = 0
    while (substr(body, fence_len + 1, 1) == fence_char) fence_len++
    in_fence = 1
    return 1
  }
  return 0
}

mode == "rules" {
  if (skip_block($0)) { in_table = 0; next }
  if (in_table) {
    if ($0 !~ /^[ \t]*\|/) { in_table = 0; next }
    if (is_delim_row(trim($0))) next
    cells($0)
    if (NCELLS != 4) { printf "U\tcells\t%d\n", FNR; next }
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
    if (type == "") { printf "U\ttype\t%d\n", FNR; next }
    checks = spans(CELL[4])
    if (checks == "") {
      if (tolower(CELL[4]) != "none") { printf "U\tshape\t%d\n", FNR; next }
    } else {
      n = split(checks, names, " ")
      for (i = 1; i <= n; i++) if (!(names[i] in SHAPES)) { printf "U\tshape\t%d\n", FNR; next }
    }
    printf "R\t%d\t%s\t%s\t%s\t%s\t%s\n", FNR, type, globs, reference, link_target(CELL[3]), checks
    next
  }
  cells($0)
  if ($0 ~ /^[ \t]*\|/ && NCELLS == 4 && CELL[1] == "Path" && CELL[2] == "Section" && CELL[3] == "Example" && CELL[4] == "Shape") {
    headers++
    in_table = 1
  }
  next
}

mode == "order" {
  if (skip_block($0)) next
  if (done) next
  if (match($0, /^[0-9]+\.[ \t]+/)) {
    name = substr($0, RLENGTH + 1)
    if (match(name, /[:,.]/)) name = substr(name, 1, RSTART - 1)
    name = tolower(trim(name))
    alts = name
    if (index(name, " or ") > 0) {
      n = split(name, sides, / or /)
      for (i = 1; i <= n; i++) alts = alts "|" trim(sides[i])
    }
    printf "O\t%d\t%d\t%s\n", ++items, FNR, alts
    next
  }
  if (items > 0 && $0 !~ /^[ \t]*$/) done = 1
  next
}

mode == "words" {
  if (FNR == 1 && $0 ~ /^---[ \t]*$/) { in_front = 1; next }
  if (in_front) { if ($0 ~ /^---[ \t]*$/) in_front = 0; next }
  words += count_words($0)
  next
}

mode == "example" {
  if (stop) next
  if (FNR == 1 && $0 ~ /^---[ \t]*$/) { in_front = 1; next }
  if (in_front) { if ($0 ~ /^---[ \t]*$/) in_front = 0; next }
  lead_cols($0)
  if (inner) {
    run = 0
    while (substr(BODY, run + 1, 1) == "`") run++
    if (run >= 4 && substr(BODY, run + 1) ~ /^[ \t]*$/) { stop = 1; next }
    words += count_words($0)
    next
  }
  if (!opened && match(BODY, /^````+[ \t]*markdown[ \t]*$/)) {
    inner = 1
    words = 0
    next
  }
  if (BODY ~ /^(```|~~~)/ || is_atx(BODY)) opened = 1
  if (is_thematic(BODY)) { stop = 1; next }
  words += count_words($0)
  next
}

mode == "judge" && NR == FNR {
  raw[FNR] = $0
  if (FNR == 1 && $0 ~ /^---[ \t]*$/) { in_front = 1; next }
  if (in_front) { if ($0 ~ /^---[ \t]*$/) in_front = 0; next }
  words += count_words($0)
  next
}

# The lines stream: "kind TAB line TAB content", content holding tabs of its own.
mode == "judge" {
  kind = substr($0, 1, 1)
  rest = substr($0, 3)
  t = index(rest, "\t")
  line = (t > 0) ? substr(rest, 1, t - 1) + 0 : rest + 0
  content = (t > 0) ? substr(rest, t + 1) : ""
  if (kind == "H") {
    lead_cols(strip_bq(raw[line], -1))
    level = 0
    if (is_atx(BODY)) { while (substr(BODY, level + 1, 1) == "#") level++ }
    else level = (substr(BODY, 1, 1) == "=") ? 1 : 2
    section = content
    # The title is the file's first heading, whatever its level: a README
    # titled with an H2 still has its description under that title.
    if (!title_line) title_line = line
    if (level == 1 && !h1_line) h1_line = line
    if (level == 2 && line != title_line) {
      if (!h2_line) h2_line = line
      nh2++
      h2_at[nh2] = line
      h2_text[nh2] = content
    }
    prev_t = 0
    next
  }
  if (kind == "X" || kind == "T") {
    lead_cols(content)
    if (BODY != "" && !h2_line) lead = 1
  }
  if (kind != "T") { prev_t = 0; next }
  body = BODY
  if (prev_t == line - 1 && index(prev_body, "|") > 0 && is_delim_row(body)) {
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
  prev_t = line
  prev_body = body
  prev_section = (section == "") ? "top" : section
  next
}

END {
  if (mode == "rules") {
    if (headers != 1) printf "U\troute-table\t%d\n", headers
    exit 0
  }
  if (mode == "words" || mode == "example") { printf "W\t%d\n", words; exit 0 }
  if (mode != "judge") exit 0
  if (judge_values) for (i = 1; i <= nvalue; i++) printf "F\tvalue-table\t%d\t0\t%s\n", value_at[i], value_section[i]
  if (judge_order && nitems > 0) {
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
