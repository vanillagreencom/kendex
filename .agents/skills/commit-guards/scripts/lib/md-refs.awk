# md-refs.awk — what a markdown file cites, what it defines, and whether the
# citations land. Runs over the line stream md-blocks.awk emits in `lines`
# mode, so fenced code, indented code and front matter never reach it. POSIX
# awk, no gawk extensions.
#
#   -v mode=index -v src=PATH
#       H<TAB>src<TAB>slug<TAB>line<TAB>heading text, lower-cased and trimmed
#       I<TAB>src<TAB>id<TAB>line          an explicit <a id="..."> or <a name="...">
#       F<TAB>src                          the file was indexed (it may hold no heading)
#   -v mode=refs -v src=PATH [-v id_prefix=D -v id_width=3]
#       L<TAB>src<TAB>line<TAB>destination<TAB>raw   a link or reference definition
#       C<TAB>src<TAB>line<TAB>path<TAB>kind<TAB>value<TAB>raw   a code-span citation;
#                                        kind is path, section or anchor
#       D<TAB>src<TAB>line<TAB>id<TAB>section   a decision ID, with the heading
#                                        the citation names after § or empty
#   -v mode=refs -v grammar=text -v src=PATH [-v id_prefix=D -v id_width=3]
#       the same C and D records out of plain "line<TAB>text" records, for a
#       caller feeding comment text or manifest strings rather than the
#       markdown line stream. Only the `§` forms are read there — a
#       `<path>.md § Heading` citation and a decision ID carrying one:
#       outside markdown a link, a bare path and a bare ID are prose, and a
#       heading with prose after it is the § rule's.
#   -v mode=resolve -v phase=targets|verdict -v tracked=FILE
#         [-v headings=FILE -v dec_dir=DIR -v dec_judge=0|1 -v id_prefix=D]
#       reads the refs records; `targets` prints each tracked markdown path a
#       heading citation needs indexed, `verdict` prints
#       V<TAB>src<TAB>line<TAB>message per dead reference and a final
#       N<TAB>count of references judged
#
# Loaded beside md-slug.awk, which holds the text reductions this file calls
# (split_spans, slugify) and reads PRINTABLE, CONTROLS and ESCAPABLE from the
# BEGIN block below.

function rtrim(s) { sub(/[ \t]+$/, "", s); return s }
function ltrim(s) { sub(/^[ \t]+/, "", s); return s }

function emit_heading(text,   base, slug, n) {
  base = slugify(text)
  slug = base
  if (slug in used) {
    n = 1
    slug = base "-" n
    while (slug in used) {
      n++
      slug = base "-" n
    }
  }
  used[slug] = 1
  printf "H\t%s\t%s\t%d\t%s\n", src, slug, line_no, tolower(rtrim(ltrim(text)))
}

function emit_explicit(content,   s, id) {
  s = content
  while (match(s, /<a[ \t]+(id|name)[ \t]*=[ \t]*["'][^"']*["']/)) {
    id = substr(s, RSTART, RLENGTH)
    sub(/^<a[ \t]+(id|name)[ \t]*=[ \t]*["']/, "", id)
    sub(/["']$/, "", id)
    printf "I\t%s\t%s\t%d\n", src, id, line_no
    s = substr(s, RSTART + RLENGTH)
  }
}

# Parse the destination and retain its enclosing link's closing position.
# Angle destinations, escaped punctuation, and optional titles share this read.
function parse_dest(s, p,   c, out, depth, title) {
  LINK_CLOSE = 0
  while (p <= length(s) && substr(s, p, 1) ~ /[ \t]/) p++
  out = ""
  if (substr(s, p, 1) == "<") {
    p++
    while (p <= length(s)) {
      c = substr(s, p, 1)
      if (c == ">") { p++; break }
      if (c == "\\" && index(ESCAPABLE, substr(s, p + 1, 1)) > 0) { out = out substr(s, p + 1, 1); p += 2; continue }
      out = out c
      p++
    }
  } else {
    depth = 0
    while (p <= length(s)) {
      c = substr(s, p, 1)
      if (c == "\\" && index(ESCAPABLE, substr(s, p + 1, 1)) > 0) { out = out substr(s, p + 1, 1); p += 2; continue }
      if (c ~ /[ \t]/) break
      if (c == "(") depth++
      else if (c == ")") { if (depth == 0) break; depth-- }
      out = out c
      p++
    }
  }
  while (p <= length(s) && substr(s, p, 1) ~ /[ \t]/) p++
  title = substr(s, p, 1)
  if (title == "\"" || title == "\047" || title == "(") {
    p++
    depth = 1
    while (p <= length(s) && depth > 0) {
      c = substr(s, p, 1)
      if (c == "\\" && index(ESCAPABLE, substr(s, p + 1, 1)) > 0) { p += 2; continue }
      if (title == "(" && c == "(") depth++
      else if (c == (title == "(" ? ")" : title)) depth--
      p++
    }
    if (depth > 0) return out
    while (p <= length(s) && substr(s, p, 1) ~ /[ \t]/) p++
  }
  if (substr(s, p, 1) == ")") LINK_CLOSE = p
  return out
}

# Relative, no scheme, no leading slash: the references this lane judges.
function is_local(dest) {
  if (dest == "") return 0
  if (dest ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) return 0
  if (dest ~ /^\//) return 0
  return 1
}

function emit_links(s, original,   i, j, k, dest, raw, tail, path) {
  i = 1
  while (1) {
    j = index(substr(s, i), "](")
    if (j == 0) break
    j = i + j - 1
    dest = parse_dest(s, j + 2)
    k = LINK_CLOSE
    raw = (k > 0) ? substr(s, j, k - j + 1) : substr(s, j)
    if (is_local(dest)) {
      printf "L\t%s\t%d\t%s\t%s\n", src, line_no, dest, raw
      tail = (k > 0) ? substr(original, k + 1) : ""
      path = dest
      sub(/#.*/, "", path)
      if ((path == "" || path ~ /\.md$/) && tail ~ /^[ \t]+§[ \t]+/) {
        sub(/^[ \t]+§[ \t]+/, "", tail)
        printf "C\t%s\t%d\t%s\tprefix-section\t%s\t%s\n", src, line_no, path, tail, dest " § " tail
      }
    }
    i = (k > 0) ? k + 1 : j + 2
  }
  if (s ~ /^[ \t]*\[[^][]+\]:[ \t]*[^ \t]/) {
    j = index(s, "]:")
    dest = parse_dest(s, j + 2)
    if (is_local(dest)) printf "L\t%s\t%d\t%s\t%s\n", src, line_no, dest, rtrim(ltrim(s))
  }
}

# A path alone in a code span is a file being named, not cited: a default
# value, a file a skill writes, a convention. Only the § and # forms point a
# reader at a place in a file, so only they are judged.
function emit_citation(span,   path, rest, i) {
  i = index(span, SECTION_SEP)
  if (i > 0) {
    path = substr(span, 1, i - 1)
    rest = rtrim(substr(span, i + length(SECTION_SEP)))
    if (path ~ /^[A-Za-z0-9._\/-]*\.md$/ && rest != "") printf "C\t%s\t%d\t%s\tsection\t%s\t%s\n", src, line_no, path, rest, span
    return
  }
  i = index(span, "#")
  if (i > 0) {
    path = substr(span, 1, i - 1)
    rest = substr(span, i + 1)
    if (path ~ /^[A-Za-z0-9._\/-]*\.md$/ && rest ~ /^[^ \t]+$/) printf "C\t%s\t%d\t%s\tanchor\t%s\t%s\n", src, line_no, path, rest, span
  }
}

# PREFIX then at least WIDTH digits, bounded by non-alphanumerics. A `§`
# right after the ID cites a section of that decision's file; the heading
# runs to the end of the line, and the prefix rule allows prose after it.
# In plain text only the `§` form is a citation: a bare ID there is prose,
# and the caller's pre-filter is free to open only the files that hold a §.
function emit_ids(s,   i, p, q, n, before, after, tail, section) {
  if (id_prefix == "") return
  p = 1
  while (1) {
    i = index(substr(s, p), id_prefix)
    if (i == 0) return
    i = p + i - 1
    q = i + length(id_prefix)
    n = 0
    while (substr(s, q + n, 1) ~ /^[0-9]$/) n++
    before = (i > 1) ? substr(s, i - 1, 1) : ""
    after = substr(s, q + n, 1)
    # In plain text a `:` or `/` before the ID glues it to a URL or a path
    # segment, which is prose there, as it is for a path citation.
    if (n >= id_width && before !~ /^[A-Za-z0-9]$/ && after !~ /^[A-Za-z0-9]$/ \
        && !(grammar == "text" && (before == ":" || before == "/"))) {
      tail = substr(s, q + n)
      section = (index(tail, SECTION_SEP) == 1) ? rtrim(substr(tail, length(SECTION_SEP) + 1)) : ""
      if (grammar != "text" || section != "") \
        printf "D\t%s\t%d\t%s\t%s\n", src, line_no, substr(s, i, q + n - i), section
    }
    p = q + (n > 0 ? n : 1)
  }
}

# A doc-section citation in plain text: the path token before ` § `, and the
# rest of the line as the heading the prefix rule judges. A token that is not
# a markdown path is prose naming a section and cites nothing.
function emit_text_citation(s,   p, i, j, path, rest, before) {
  p = 1
  while (1) {
    i = index(substr(s, p), SECTION_SEP)
    if (i == 0) return
    i = p + i - 1
    j = i
    while (j > 1 && substr(s, j - 1, 1) ~ /^[A-Za-z0-9._\/-]$/) j--
    path = substr(s, j, i - j)
    rest = rtrim(substr(s, i + length(SECTION_SEP)))
    before = (j > 1) ? substr(s, j - 1, 1) : ""
    # A bare `.md` is what the walk back leaves of a placeholder such as
    # `<path>.md`, whose brackets end the token; it names no file. A `:`
    # before the token, or a `//` opening it, is the tail of a URL the walk
    # back could not cross: is_local() refuses the same shapes in markdown,
    # and outside it a link is prose.
    if (path ~ /\.md$/ && path != ".md" && path !~ /\/\.md$/ && path !~ /^\/\// \
        && before != ":" && rest != "") \
      printf "C\t%s\t%d\t%s\tprefix-section\t%s\t%s\n", src, line_no, path, rest, path SECTION_SEP rest
    p = i + length(SECTION_SEP)
  }
}

# A `..`-walking normalisation; sets ESCAPED when it climbs past the root.
function normalize(p,   n, parts, i, top, stack, out) {
  ESCAPED = 0
  n = split(p, parts, "/")
  top = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == ".") continue
    if (parts[i] == "..") {
      if (top == 0) { ESCAPED = 1; return "" }
      top--
      continue
    }
    stack[++top] = parts[i]
  }
  out = ""
  for (i = 1; i <= top; i++) out = out (i == 1 ? "" : "/") stack[i]
  return out
}

function dir_of(path,   d) {
  d = path
  if (!sub(/\/[^\/]*$/, "", d)) d = ""
  return d
}

function resolve_from(base_dir, rel) {
  return (base_dir == "") ? normalize(rel) : normalize(base_dir "/" rel)
}

function load_tracked(   line, d, rec, id) {
  while ((getline line < tracked) > 0) {
    tracked_set[line] = 1
    d = line
    while (sub(/\/[^\/]*$/, "", d)) dirs[d] = 1
    if (dec_judge && dec_dir != "" && index(line, dec_dir "/") == 1) {
      d = substr(line, length(dec_dir) + 2)
      if (match(d, /^[^\/]+/)) {
        rec = substr(d, 1, RLENGTH)
        if (index(rec, id_prefix) == 1 && match(substr(rec, length(id_prefix) + 1), /^[0-9]+/)) {
          id = substr(rec, 1, length(id_prefix) + RLENGTH)
          decisions[id] = 1
          # The record itself, when the ID names one markdown file rather
          # than a directory: a § citation reads its headings from there.
          if (rec == d && d ~ /\.md$/ && !(id in decfile)) decfile[id] = line
        }
      }
    }
  }
  close(tracked)
}

function load_headings(   line, f) {
  if (headings == "") return
  while ((getline line < headings) > 0) {
    split(line, f, "\t")
    if (f[1] == "H") { slugs[f[2] "#" f[3]] = 1; texts[f[2] "#" f[5]] = 1 }
    else if (f[1] == "I") slugs[f[2] "#" f[3]] = 1
  }
  close(headings)
}

# A bare section route starts with an existing heading; prose may follow it.
# Exact code-span citations and anchor links keep their exact-match rules.
function has_section_prefix(target, value,   key, prefix, name, tail, number) {
  prefix = target "#"
  value = tolower(value)
  gsub(/[`*_]/, "", value)
  number = ""
  if (match(value, /^[0-9]+(\.[0-9]+)*/) && substr(value, RLENGTH + 1) ~ /^([ \t.,;:!?)]|$)/) number = substr(value, 1, RLENGTH)
  for (key in texts) {
    if (index(key, prefix) != 1) continue
    name = substr(key, length(prefix) + 1)
    gsub(/[`*_]/, "", name)
    if (number != "") {
      if (match(name, /^[0-9]+(\.[0-9]+)*/) && substr(name, 1, RLENGTH) == number && substr(name, RLENGTH + 1) ~ /^[.)]?([ \t]|$)/) return 1
      continue
    }
    if (name == "" || substr(value, 1, length(name)) != name) continue
    tail = substr(value, length(name) + 1)
    if (tail == "" || tail ~ /^[ \t.,;:!?)]/) return 1
  }
  return 0
}

function fail(msg) { if (phase == "verdict") printf "V\t%s\t%d\t%s\n", src_path, line_no, msg }

function want_target(t) { if (phase == "targets" && !(t in wanted)) { wanted[t] = 1; print t } }

BEGIN {
  SECTION_SEP = " § "
  for (i = 32; i <= 126; i++) {
    c = sprintf("%c", i)
    PRINTABLE = PRINTABLE c
    if (c !~ /^[A-Za-z0-9]$/ && c != " ") ESCAPABLE = ESCAPABLE c
  }
  for (i = 1; i <= 31; i++) CONTROLS = CONTROLS sprintf("%c", i)
  CONTROLS = CONTROLS sprintf("%c", 127)
  if (mode == "resolve") {
    if (phase != "targets" && phase != "verdict") {
      printf "md-refs.awk: phase must be targets or verdict (got '%s')\n", phase > "/dev/stderr"
      exit 2
    }
    load_tracked()
    if (phase == "verdict") load_headings()
    judged = 0
  } else if (mode == "index") {
    printf "F\t%s\n", src
  } else if (mode != "refs") {
    printf "md-refs.awk: mode must be index, refs or resolve (got '%s')\n", mode > "/dev/stderr"
    exit 2
  }
}

mode == "index" {
  split($0, f, "\t")
  line_no = f[2]
  if (f[1] == "H") emit_heading(f[3])
  else emit_explicit(f[3])
  next
}

# Plain text arrives as "line<TAB>text": the text is everything after the
# first tab, because comment text carries tabs of its own.
mode == "refs" && grammar == "text" {
  i = index($0, "\t")
  if (i == 0) next
  line_no = substr($0, 1, i - 1)
  text = substr($0, i + 1)
  emit_text_citation(text)
  emit_ids(text)
  next
}

mode == "refs" {
  split($0, f, "\t")
  line_no = f[2]
  if (f[1] == "H") next
  if (f[1] == "X") {
    emit_ids(f[3])
    next
  }
  split_spans(f[3])
  for (i = 1; i <= nspans; i++) emit_citation(spans[i])
  emit_links(outside, f[3])
  emit_ids(f[3])
  next
}

mode == "resolve" {
  split($0, f, "\t")
  kind = f[1]
  src_path = f[2]
  line_no = f[3]
  # Only normalize() sets ESCAPED, and a bare `#anchor` never calls it, so
  # the flag is this record's only once it is cleared here.
  ESCAPED = 0
  if (kind == "L") {
    dest = f[4]
    raw = f[5]
    hash = index(dest, "#")
    anchor = ""
    path = dest
    if (hash > 0) { path = substr(dest, 1, hash - 1); anchor = substr(dest, hash + 1) }
    sub(/\/$/, "", path)
    if (path == "") target = src_path
    else target = resolve_from(dir_of(src_path), path)
    judged++
    if (ESCAPED) { fail(raw ": the link climbs above the repository root"); next }
    if (!(target in tracked_set) && !(target in dirs)) { fail(raw ": no tracked file or directory at " target); next }
    if (anchor == "") next
    if (target !~ /\.md$/) { fail(raw ": an anchor into a file that is not markdown"); next }
    want_target(target)
    if (!((target "#" anchor) in slugs)) fail(raw ": " target " has no heading or explicit anchor #" anchor)
    next
  }
  if (kind == "C") {
    path = f[4]
    ckind = f[5]
    value = f[6]
    raw = f[7]
    judged++
    target = (path == "") ? src_path : resolve_from(dir_of(src_path), path)
    if (ESCAPED || !(target in tracked_set)) {
      target = normalize(path)
      if (ESCAPED || !(target in tracked_set)) {
        fail("`" raw "`: no tracked file at " path " beside " src_path " or at the repository root")
        next
      }
    }
    want_target(target)
    if (ckind == "section") {
      if (!((target "#" tolower(value)) in texts)) fail("`" raw "`: " target " has no heading '" value "'")
    } else if (ckind == "prefix-section") {
      if (!has_section_prefix(target, value)) fail(raw ": " target " has no heading at the start of '" value "'")
    } else if (!((target "#" value) in slugs)) fail("`" raw "`: " target " has no heading or explicit anchor #" value)
    next
  }
  if (kind == "D") {
    if (!dec_judge) next
    judged++
    if (!(f[4] in decisions)) { fail(f[4] ": no tracked decision file " dec_dir "/" f[4] "-*.md"); next }
    if (f[5] == "") next
    if (!(f[4] in decfile)) {
      fail(f[4] SECTION_SEP f[5] ": no tracked markdown file " dec_dir "/" f[4] "-*.md to read a heading from")
      next
    }
    want_target(decfile[f[4]])
    if (!has_section_prefix(decfile[f[4]], f[5])) \
      fail(f[4] SECTION_SEP f[5] ": " decfile[f[4]] " has no heading at the start of '" f[5] "'")
    next
  }
}

END {
  if (mode == "resolve" && phase == "verdict") printf "N\t%d\n", judged
}
