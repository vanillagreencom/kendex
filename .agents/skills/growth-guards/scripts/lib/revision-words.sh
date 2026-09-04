# shellcheck shell=bash
# Revision patterns share settings, word boundaries, and grep case folding.

gg_load_revision_words() { # KEY DEFAULT — sets REVISION_WORDS and WORD_ERE
  local key="$1" status=0
  REVISION_WORDS="$(gg_setting "$key" "$2")" || return 2
  WORD_ERE='a^'
  [ -n "$REVISION_WORDS" ] || return 0
  WORD_ERE="(^|[^[:alnum:]_])($REVISION_WORDS)([^[:alnum:]_]|\$)"
  printf '' | LC_ALL=C grep -iE -- "$WORD_ERE" >/dev/null 2>"$GG_TMP/words.err" || status=$?
  [ "$status" -le 1 ] && [ ! -s "$GG_TMP/words.err" ] \
    || gg_config_error "$key is not a POSIX ERE grep can read"
}

gg_revision_records() { # INPUT — matching line<TAB>shape<TAB>text records
  local status=0
  [ -n "$REVISION_WORDS" ] || return 0
  # Strip record numbers before matching: a numeric word must match text.
  cut -f2- -- "$1" >"$GG_TMP/words.text" \
    || gg_collection_error "could not read revision text"
  LC_ALL=C grep -inE -- "$WORD_ERE" "$GG_TMP/words.text" >"$GG_TMP/words.hits" || status=$?
  [ "$status" -le 1 ] || gg_collection_error "could not match revision text"
  [ "$status" -eq 0 ] || return 0
  LC_ALL=C awk -F '\t' -v OFS='\t' '
    FILENAME == ARGV[1] { split($0, fields, ":"); hits[fields[1]] = 1; next }
    FNR in hits { print $1, "revision narration", substr($0, length($1) + 2) }
  ' "$GG_TMP/words.hits" "$1" \
    || gg_collection_error "could not map revision matches to source lines"
}
