# md-slug.awk — the text reductions md-refs.awk calls: code spans split
# from the text around them, and a heading reduced to the anchor GitHub
# generates for it. Loaded as a second `-f` program beside md-refs.awk,
# never alone; POSIX awk.
#
# The slug is GitHub's: the rendered heading text lower-cased, every
# character that is not a letter, a digit, a space, `-` or `_` dropped, each
# space a hyphen, and `-1`, `-2` on a repeat, taking the first free suffix
# (the suffix walk is emit_heading's, in md-refs.awk). Link syntax,
# code-span backticks and HTML tags reduce to their text first. Non-ASCII
# letters stay; the non-ASCII punctuation GitHub drops is listed in
# drop_punct, and any other multibyte character is kept as a letter.

# The text of every code span in S into spans[1..nspans], and the text
# between them into `outside`, each span replaced by spaces of equal length. Runs of
# backticks pair by length; an unmatched run is literal text.
function split_spans(s,   i, n, rest, p, j, k, m, found) {
  nspans = 0
  outside = ""
  while (1) {
    i = index(s, "`")
    if (i == 0) {
      outside = outside s
      return
    }
    outside = outside substr(s, 1, i - 1)
    s = substr(s, i)
    n = 0
    while (substr(s, n + 1, 1) == "`") n++
    rest = substr(s, n + 1)
    p = 1
    found = 0
    while (1) {
      j = index(substr(rest, p), "`")
      if (j == 0) break
      k = p + j - 1
      m = 0
      while (substr(rest, k + m, 1) == "`") m++
      if (m == n) { found = k; break }
      p = k + m
    }
    if (found > 0) {
      nspans++
      spans[nspans] = substr(rest, 1, found - 1)
      outside = outside sprintf("%*s", found + 2 * n - 1, "")
      s = substr(rest, found + n)
    } else {
      outside = outside substr(s, 1, n)
      s = rest
    }
  }
}

# `[text](dest)` and `[text][ref]` reduce to `text`; a bracket pair that is
# neither stays as written.
function unlink_text(s,   out, i, j, label, rest, k) {
  out = ""
  while (1) {
    i = index(s, "[")
    if (i == 0) return out s
    out = out substr(s, 1, i - 1)
    s = substr(s, i)
    j = index(s, "]")
    if (j == 0) return out s
    label = substr(s, 2, j - 2)
    rest = substr(s, j + 1)
    if (substr(rest, 1, 1) == "(" || substr(rest, 1, 1) == "[") {
      k = index(rest, substr(rest, 1, 1) == "(" ? ")" : "]")
      if (k > 0) {
        out = out label
        s = substr(rest, k + 1)
        continue
      }
    }
    out = out substr(s, 1, j)
    s = rest
  }
}

# Raw HTML tags reduce to nothing; a `<` that opens no tag is text.
function strip_tags(s,   out, i, j) {
  out = ""
  while (1) {
    i = index(s, "<")
    if (i == 0) return out s
    j = index(substr(s, i), ">")
    if (j > 0 && substr(s, i + 1) ~ /^\/?[A-Za-z][A-Za-z0-9-]*([ \t>]|\/>)/) {
      out = out substr(s, 1, i - 1)
      s = substr(s, i + j)
    } else {
      out = out substr(s, 1, i)
      s = substr(s, i + 1)
    }
  }
}

# Section routes compare displayed text. Paired delimiters disappear; literal
# markers and intraword underscores stay, including all code-span content.
function section_text(s,   out, i, j, n, m, c, before, after, inner) {
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c !~ /[`*_]/) { out = out c; continue }
    n = 1
    while (substr(s, i + n, 1) == c) n++
    before = (i == 1) ? "" : substr(s, i - 1, 1)
    after = substr(s, i + n, 1)
    if (before != "\\" && (c == "`" || (after !~ /^[ \t]$/ && after != "" && (c != "_" || before !~ /^[[:alnum:]]$/)))) {
      for (j = i + n; j <= length(s); j += m) {
        m = 1
        if (substr(s, j, 1) != c) continue
        while (substr(s, j + m, 1) == c) m++
        if (m != n) continue
        before = substr(s, j - 1, 1)
        after = substr(s, j + m, 1)
        if (c != "`" && (before ~ /^[ \t\\]$/ || (c == "_" && after ~ /^[[:alnum:]]$/))) continue
        inner = substr(s, i + n, j - i - n)
        if (inner == "") continue
        out = out ((c == "`") ? inner : section_text(inner))
        i = j + m - 1
        break
      }
      if (j <= length(s)) continue
    }
    out = out substr(s, i, n)
    i += n - 1
  }
  return out
}

function drop_punct(s) {
  gsub(/—/, "", s); gsub(/–/, "", s); gsub(/―/, "", s)
  gsub(/→/, "", s); gsub(/←/, "", s); gsub(/↳/, "", s); gsub(/§/, "", s)
  gsub(/“/, "", s); gsub(/”/, "", s); gsub(/‘/, "", s); gsub(/’/, "", s)
  gsub(/…/, "", s); gsub(/×/, "", s); gsub(/÷/, "", s); gsub(/•/, "", s)
  gsub(/✓/, "", s); gsub(/≥/, "", s); gsub(/≤/, "", s); gsub(/≠/, "", s)
  return s
}

function slugify(text,   s, out, i, c) {
  s = unlink_text(text)
  gsub(/`/, "", s)
  s = strip_tags(s)
  s = tolower(s)
  s = drop_punct(s)
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == " " || c == "\t") out = out " "
    else if (c ~ /^[a-z0-9_-]$/) out = out c
    else if (index(PRINTABLE, c) > 0) continue
    else if (index(CONTROLS, c) > 0) continue
    else out = out c
  }
  sub(/^ +/, "", out)
  sub(/ +$/, "", out)
  gsub(/ /, "-", out)
  return out
}

