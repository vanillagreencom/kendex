# shellcheck shell=bash
# Comment text out of a source file, for the comments lane: which grammar a
# path takes, and the scanner that walks a file under it. Sourced by
# scripts/comments; needs gg_collection_error and GG_TMP from lib/common.sh.
#
# The scanner is a character walk with code, string, block-comment and
# heredoc-body states carried across lines. A quoted shell command
# substitution saves its outer string while its shell body is scanned. It
# emits one
# "line<TAB>text" record per line of comment text and nothing for code or
# a string literal. A file that ends in any state but code is not
# extractable: every comment after the opener would otherwise be swallowed
# and the file counted clean. It is not a parser: what it does not model is
# stated in CHECKS.md § comments, and the controls in tests/comments.test.sh
# hold each stated limit to its statement.
#
# Bash 3.2-safe, like its parent; the awk inside is POSIX awk — no interval
# expressions, no gensub, no IGNORECASE.

# The grammar a path takes: its extension first, and for a path with none
# the interpreter its shebang names. Prints nothing for a path this lane has
# no grammar for. The table this spells is CHECKS.md § comments.
gg_comment_family() { # PATH BLOBFILE — family token on stdout, empty when none
  local path="$1" blob="$2" base ext first
  base="${path##*/}"
  case "$base" in
    Makefile | *.mk | Dockerfile)
      printf 'hash-plain'
      return 0
      ;;
  esac
  case "$base" in
    *.*) ext="${base##*.}" ;;
    *) ext="" ;;
  esac
  case "$ext" in
    rs) printf 'c-rust' ;;
    go | js | mjs | cjs | jsx | ts | tsx) printf 'c-tmpl' ;;
    c | h | cc | cpp | hpp | java | kt | kts | swift | wgsl | scss | less) printf 'c' ;;
    css) printf 'cblock' ;;
    sh | bash | zsh) printf 'hash-shell' ;;
    py) printf 'hash-py' ;;
    rb) printf 'hash-rb' ;;
    toml) printf 'hash-toml' ;;
    yml | yaml) printf 'hash-plain' ;;
    sql) printf 'sql' ;;
    lua) printf 'lua' ;;
    html | htm | xml | svg | vue | svelte) printf 'xml' ;;
    "")
      # No extension: the shebang decides, and only a shebang does.
      first="$(head -n 1 -- "$blob" | LC_ALL=C tr -d '\r')" \
        || gg_collection_error "could not read the first line of $(gg_shown "$path")"
      case "$first" in
        "#!"*) ;;
        *) return 0 ;;
      esac
      case "$first" in
        *sh | *sh[[:space:]]* | *env[[:space:]]*sh*) printf 'hash-shell' ;;
        *python*) printf 'hash-py' ;;
        *ruby*) printf 'hash-rb' ;;
        *node* | *deno* | *bun*) printf 'c-tmpl' ;;
      esac
      ;;
  esac
}

# The comment text of one file under one grammar, as "line<TAB>text"
# records. A block comment spanning lines emits one record per line. A
# shebang on line 1 of a hash-family file is not a comment. PATH is the
# name a diagnostic gives the file; FILE is the blob it reads.
gg_comment_text() { # FAMILY FILE PATH — records on stdout
  local fam="$1" file="$2" path="$3" status=0 reason
  GG_COMMENT_ERROR=""
  local base=c rust=0 tmpl=0 shell=0 esc_single=1 triple=0 str_multi=0
  case "$fam" in
    c) ;;
    # A Rust string literal spans lines, with or without a trailing
    # backslash; a C or JavaScript one ends at the line.
    c-rust) rust=1 str_multi=1 ;;
    c-tmpl) tmpl=1 ;;
    cblock) base=cblock ;;
    hash-shell) base=hash shell=1 esc_single=0 str_multi=1 ;;
    hash-py) base=hash triple=1 ;;
    hash-rb) base=hash ;;
    hash-toml) base=hash esc_single=0 triple=1 ;;
    hash-plain) base=hash esc_single=0 ;;
    sql | lua | xml) base="$fam" ;;
    *) gg_collection_error "gg_comment_text: unknown comment family '$fam'" ;;
  esac
  # The apostrophe arrives as a variable: the program is a single-quoted
  # literal, and not every awk reads a hex escape.
  LC_ALL=C awk -v fam="$base" -v rust="$rust" -v tmpl="$tmpl" -v shell="$shell" \
    -v esc_single="$esc_single" -v triple="$triple" -v str_multi="$str_multi" -v sq="'" '
  function word(ch) { return ch ~ /[A-Za-z0-9_]/ }
  # Whether S ends inside an arithmetic `((`: more openers than closers.
  function in_arith(s,   n, k) {
    n = 0
    while ((k = index(s, "((")) > 0) { n++; s = substr(s, k + 2) }
    return n > gsub(/\)\)/, "", s)
  }
  BEGIN {
    st = "code"; d = ""; e = 0; m = 0; pend = ""; hdw = ""; hds = 0; opened = 0; subn = 0
    if (fam == "c") { bo = "/*"; bc = "*/"; lead = "//"; cls = "[\"" sq "/" (tmpl ? "`" : "") "]" }
    else if (fam == "cblock") { bo = "/*"; bc = "*/"; lead = ""; cls = "[\"" sq "/]" }
    else if (fam == "hash") { bo = ""; bc = ""; lead = "#"; cls = "[\"" sq "#" (shell ? "<()\\\\" : "") "]" }
    else if (fam == "sql") { bo = "/*"; bc = "*/"; lead = "--"; cls = "[\"" sq "/-]" }
    else if (fam == "lua") { bo = "--[["; bc = "]]"; lead = "--"; cls = "[\"" sq "-]" }
    else if (fam == "xml") { bo = "<!--"; bc = "-->"; lead = ""; cls = "[<]" }
    else { print "gg_comment_text: unknown base family " fam > "/dev/stderr"; st = "bad"; exit 3 }
  }
  {
    line = $0; n = length(line); i = 1
    if (NR == 1 && fam == "hash" && substr(line, 1, 2) == "#!") next
    if (st == "heredoc") {
      probe = line
      if (hds) sub(/^\t+/, "", probe)
      if (probe == hdw) st = "code"
      next
    }
    if (st == "block") {
      j = index(line, bc)
      if (j == 0) { print NR "\t" line; next }
      print NR "\t" substr(line, 1, j - 1)
      i = j + length(bc); st = "code"
    }
    while (i <= n) {
      if (st == "str") {
        # Inside a literal only its closer and an escape matter.
        rest = substr(line, i)
        if (!match(rest, scls)) { i = n + 1; break }
        i += RSTART - 1
        c = substr(line, i, 1)
        # Double quotes around $(...) remain open while the substitution is
        # scanned for the shell shapes this extractor tracks. Save the outer
        # literal so quotes and heredocs in that code cannot replace it.
        if (shell && d == "\"" && c == "$" && substr(line, i, 2) == "$(") {
          subn++
          subdepth[subn] = 1; subd[subn] = d; sube[subn] = e; subm[subn] = m
          subopened[subn] = opened; subscls[subn] = scls; substart[subn] = NR
          st = "code"; i += 2; continue
        }
        if (c == "$") { i++; continue }
        if (e && c == "\\") { i += 2; continue }
        if (substr(line, i, length(d)) == d) { st = "code"; i += length(d); continue }
        i++; continue
      }
      rest = substr(line, i)
      if (!match(rest, cls)) break
      i += RSTART - 1
      c = substr(line, i, 1)
      if (bo != "" && substr(line, i, length(bo)) == bo) {
        j = index(substr(line, i + length(bo)), bc)
        if (j == 0) { print NR "\t" substr(line, i + length(bo)); st = "block"; opened = NR; i = n + 1; break }
        print NR "\t" substr(line, i + length(bo), j - 1)
        i += length(bo) + j - 1 + length(bc); continue
      }
      if (lead != "" && substr(line, i, length(lead)) == lead) {
        # A hash opens a comment only at the start of a word: `$#` and
        # `${x#y}` are not comments, and neither is a fragment glued to a
        # URL or a key.
        if (fam == "hash" && i > 1 && substr(line, i - 1, 1) !~ /[ \t]/) { i++; continue }
        t = substr(line, i + length(lead))
        if (fam == "c") sub(/^[\/!]/, "", t)
        print NR "\t" t
        i = n + 1; break
      }
      if (shell && subn > 0 && c == "(") { subdepth[subn]++; i++; continue }
      if (shell && subn > 0 && c == "\\") { i += 2; continue }
      if (shell && subn > 0 && c == ")") {
        subdepth[subn]--
        if (subdepth[subn] == 0) {
          st = "str"; d = subd[subn]; e = sube[subn]; m = subm[subn]
          opened = subopened[subn]; scls = subscls[subn]
          delete subdepth[subn]; delete subd[subn]; delete sube[subn]; delete subm[subn]
          delete subopened[subn]; delete subscls[subn]; delete substart[subn]
          subn--
        }
        i++; continue
      }
      if (c == "<") {
        # A shell heredoc: its body starts on the next line and is neither
        # code nor comment until the terminator line. `<<<` is a here-string
        # and `<<` inside `((...))` is a shift. The word is any run up to a
        # blank or an operator character, its quotes stripped, so the
        # terminator line is matched whole (`END-OF`, not `END`).
        if (shell && substr(line, i, 3) == "<<<") { i += 3; continue }
        if (shell && substr(line, i, 2) == "<<" && !in_arith(substr(line, 1, i - 1))) {
          rest = substr(line, i + 2); hdflag = 0
          if (substr(rest, 1, 1) == "-") { hdflag = 1; rest = substr(rest, 2) }
          sub(/^[ \t]*/, "", rest)
          q = substr(rest, 1, 1)
          if (q == "\\") { rest = substr(rest, 2); q = "" }
          if (q == sq || q == "\"") {
            rest = substr(rest, 2)
            j = index(rest, q)
            w = (j > 0) ? substr(rest, 1, j - 1) : rest
          } else {
            match(rest, /^[^ \t&;|<>]*/)
            w = substr(rest, 1, RLENGTH)
          }
          if (pend == "" && w != "") { pend = w; hds = hdflag }
          i += 2; continue
        }
        i++; continue
      }
      # Anything else the class lists is a leader that did not complete
      # (a lone slash or dash) and opens nothing.
      if (c != "\"" && c != sq && c != "`") { i++; continue }
      if (c == sq && rust) {
        # A char literal is one char (or one escape) between quotes; any
        # other quote is a lifetime or a label and opens nothing.
        if (substr(line, i, 2) == sq "\\") {
          j = index(substr(line, i + 3), sq)
          i = (j == 0) ? n + 1 : i + 3 + j
          continue
        }
        if (substr(line, i + 2, 1) == sq) { i += 3; continue }
        i++; continue
      }
      d = c; e = 1; m = (c == "`") ? 1 : str_multi
      if (rust && c == "\"") {
        # r"..." and r#"..."# close only on the quote followed by as many
        # hashes as opened it, with no escapes inside.
        k = i - 1; h = 0
        while (k >= 1 && substr(line, k, 1) == "#") { k--; h++ }
        if (k >= 1 && substr(line, k, 1) == "r" \
            && (k == 1 || !word(substr(line, k - 1, 1)) \
                || (substr(line, k - 1, 1) == "b" && (k == 2 || !word(substr(line, k - 2, 1)))))) {
          d = "\""; while (h-- > 0) d = d "#"
          e = 0; m = 1
        }
      }
      if (triple && substr(line, i, 3) == c c c) { d = c c c; m = 1 }
      if (fam == "hash" && c == sq) {
        if (!esc_single) e = 0
        if (shell && i > 1 && substr(line, i - 1, 1) == "$") e = 1
      }
      scls = "[" c "\\\\" ((shell && c == "\"") ? "$" : "") "]"
      st = "str"; opened = NR; i += length(d)
    }
    if (pend != "") { st = "heredoc"; hdw = pend; pend = ""; opened = NR }
    else if (st == "str" && !m) st = "code"
  }
  END {
    if (st == "bad") exit 3
    if (st == "code" && subn == 0) exit 0
    if (st == "block") what = "a block comment"
    else if (st == "heredoc") what = "a heredoc (terminator " hdw ")"
    else if (st == "code" && subn > 0) { what = "a command substitution"; opened = substart[subn] }
    else what = "a string literal"
    print what " opened at line " opened " is never closed" > "/dev/stderr"
    exit 3
  }
  ' "$file" 2>"$GG_TMP/extract.err" || status=$?
  if [ "$status" -ne 0 ]; then
    reason="$(LC_ALL=C tr '\n' ' ' <"$GG_TMP/extract.err")"
    GG_COMMENT_ERROR="${reason:-awk exit $status}"
    return "$status"
  fi
}
