# md-type.awk — md-type's readings: docs-writing's route table as data, an
# example's document, and a file's word count. POSIX awk, loaded after
# md-shapes.awk. Parsed only by scripts/md-type.
#
# The rules and words modes read md-blocks.awk's lines stream, the one
# reading of a file's block structure, so a fence or front matter is skipped
# by the grammar md-reflow and md-refs use.
#
#   -v mode=rules    SKILL.md's lines stream -> "R line type globs reference
#                    example" per route row, tab-separated, "-" for an empty
#                    cell; "U detector line" when the table breaks the
#                    contract (one Path|Section|Example table, three cells a
#                    row); "W line" for the retired table with a fourth
#                    Shape column, whose rows of four cells read with that
#                    cell ignored
#   -v mode=example  an example file -> its document's lines: the content of
#                    its first `markdown` fence before any thematic break,
#                    else the file up to its first thematic break, front
#                    matter excluded. A raw read, because the lines stream
#                    emits no fence content.
#   -v mode=words    two files, the sized file then md-blocks' lines stream
#                    for it -> the stream's word count. The sized file is read
#                    only to tell an ATX heading, whose text the stream's H
#                    record alone carries, from a Setext one, whose text
#                    arrived as T records.

BEGIN {
  FS = "\n"
  if (mode != "rules" && mode != "example" && mode != "words") {
    printf "md-type: mode=%s\n  Expected rules, example or words.\n", mode > "/dev/stderr"
    exit 2
  }
  in_front = 0
  headers = 0
  in_table = 0
  words = 0
  ndoc = 0
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
    if (NCELLS != table_cells) { printf "U\tcells\t%d\n", LINE; next }
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
    # md-type reads these with a tab IFS, which merges adjacent tabs: an
    # empty cell is written "-" so no field shifts into its neighbour.
    printf "R\t%d\t%s\t%s\t%s\t%s\n", LINE, type, dash(globs), dash(reference), dash(link_target(CELL[3]))
    next
  }
  cells(CONTENT)
  if (CONTENT ~ /^[ \t]*\|/ && CELL[1] == "Path" && CELL[2] == "Section" && CELL[3] == "Example" &&
      (NCELLS == 3 || (NCELLS == 4 && CELL[4] == "Shape"))) {
    headers++
    in_table = 1
    table_cells = NCELLS
    if (NCELLS == 4) printf "W\t%d\n", LINE
  }
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

mode == "words" && NR == FNR { raw[FNR] = $0; next }

mode == "words" {
  record()
  if (KIND == "T" || KIND == "X") words += count_words(CONTENT)
  else if (KIND == "H") {
    lead_cols(strip_bq(raw[LINE], -1))
    if (is_atx(BODY)) words += count_words(CONTENT)
  }
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
  print words
}
