# shellcheck shell=bash
# The lines a commit ADDS to one path, for the lanes that judge a staged
# diff by its additions. Sourced by todo-ban and comments; needs GG_TMP
# (gg_tmpdir) and the family contract from lib/common.sh.
#
# Bash 3.2-safe, like its parent.

gg_staged_added_lines() { # PATH — one "line<TAB>content" record per line this commit ADDS
  local f="$1" status=0 awk_status=0
  # Pinned diff configuration: an external differ or a textconv filter would
  # hand this lane content the commit does not carry, and colour would put
  # escape sequences in front of the leading '+'. --text is the same pin
  # against .gitattributes: a committed '-diff' rule makes git call the path
  # binary and emit 'Binary files ... differ' with no hunks, so without it a
  # repository could hide a whole extension from this lane by committing one
  # attributes line. One file per invocation, named by a literal pathspec,
  # so no patch header is ever parsed for a path — a path git would have had
  # to quote cannot be misread here.
  git -c core.quotePath=false diff --cached --no-ext-diff --no-textconv --no-color --text \
    -U0 -- ":(literal)$f" \
    >"$GG_TMP/patch" 2>"$GG_TMP/patch.err" || status=$?
  if [ "$status" -ne 0 ]; then
    [ ! -s "$GG_TMP/patch.err" ] || cat -- "$GG_TMP/patch.err" >&2
    gg_collection_error "could not read the staged additions in '$f' (git diff exit $status)"
  fi
  # Line numbers come from the hunk headers ('@@ -a,b +c,d @@'), and only
  # lines inside a hunk count — every 'diff --git' closes the hunk before
  # it, so a file header is never read as one. A type change emits TWO
  # sections for one path, and without that reset the second section's
  # '+++' line would print as a line of the diff at the first section's
  # numbering. --text above means a blob an ATTRIBUTES rule calls binary
  # still arrives as hunks, so no path reaches the parser with its content
  # withheld; a genuinely binary blob never reaches the parser at all — the
  # lane's content sniff drops it before this runs.
  # LC_ALL=C, like the grep every caller runs over this output: BWK awk — the
  # awk macOS ships — decodes its input as characters under a UTF-8 locale and
  # aborts with `towc: multibyte conversion failure`, exit 2, on the first byte
  # sequence that is not valid UTF-8. A tracked text file may hold any byte;
  # this lane's own content sniff already decided the blob is text, and a
  # scan that exits 2 is a lane that errors instead of judging.
  LC_ALL=C awk '
    /^diff --git / { hunk = 0; next }
    /^@@/ {
      h = $3
      sub(/^\+/, "", h)
      i = index(h, ",")
      ln = (i > 0 ? substr(h, 1, i - 1) : h) + 0
      hunk = 1
      next
    }
    hunk && /^\+/ { print ln "\t" substr($0, 2); ln++; next }
    hunk && /^ / { ln++; next }
  ' "$GG_TMP/patch" || awk_status=$?
  [ "$awk_status" -eq 0 ] \
    || gg_collection_error "could not parse the staged additions in '$f' (awk exit $awk_status)"
}
