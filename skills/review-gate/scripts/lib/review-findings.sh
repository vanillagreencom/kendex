# shellcheck shell=bash
# Shared review identities and suppressed-body grammar. The predicate owns
# their meaning; refresh-reviews consumes the same definitions for replies.
AUTOMATIC_AUTHOR_DEF='def automatic_author: (.__typename // .type // "User") == "Bot";'

ACCEPTED_ROWS_DEF='def not_errored_attestation($mk):
  (((.body // "") | ascii_downcase
    | sub("^[\\s>]+"; "") | split("\n") | (.[0] // "")) as $b
   | [ $mk[] | . as $p | select($b | contains($p)) ] | length) == 0;
def trust_list($trusted):
  $trusted | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0));
def error_marks($errmarks):
  $errmarks | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | map(ascii_downcase);
def own_content:
  .state == "APPROVED" or .state == "CHANGES_REQUESTED" or ((.body // "") | test("\\S"));
def candidate_rows($t; $mk; $author):
  [ .[]
    | select(.state != "DISMISSED" and .state != "PENDING" and .user.login != $author)
    | select(($t | length) == 0 or (.user.login as $l | ($t | index($l)) != null))
    | select(not_errored_attestation($mk)) ];
def accepted_rows($t; $mk; $author; $openers):
  [ candidate_rows($t; $mk; $author)[]
    | select(own_content or (.id as $id | any($openers[]; . == $id))) ];'

SUPP_NORMALIZE_DEF='def display_strip: gsub("\r"; "") | gsub("\u200b"; "");
'
# entry_marks is the decoration the review body wraps an entry token in. The
# scan reads a line so decorated and the disposition read answers a reply so
# decorated: a mark only one of them knew is an entry the author cannot clear.
SUPP_ENTRY_DEF='def entry_marks: ["**", "`"];
'
SUPP_SCAN_DEF='
    # The sentinel text of a line, whichever surface carries it: a markdown
    # heading, or the <summary> of a <details> section. The reviewer writes the
    # block on either, so ONE extractor feeds both title tests rather than a
    # regex per spelling, and a further spelling arrives as a title string
    # instead of a new arm. Inner tags go on the summary arm: a section title
    # arrives wrapped in <strong>.
    def block_title:
      if test("^#{1,6}[ \t]+") then sub("^#{1,6}[ \t]+"; "")
      elif test("^<summary[^>]*>.*</summary>[ \t]*$")
      then sub("^<summary[^>]*>"; "") | sub("</summary>[ \t]*$"; "") | gsub("<[^>]*>"; "")
      else "" end
      | sub("^[ \t]+"; "") | sub("[ \t]+$"; "");
    # The entry token a whole line carries, or nothing. A line is one of the
    # shared entry_marks, the token, the SAME mark again, and trailing blanks —
    # `path:line`, where the line number is what makes a token and the path may
    # hold any character but a mark. Iterating the list rather than branching
    # per decoration is what keeps this in step with the disposition read, which
    # iterates the same list.
    def entry_token:
      sub("[ \t]+$"; "") as $l
      | first(
          entry_marks[]
          | . as $d
          | ($d | length) as $dn
          | select(($l | length) > (2 * $dn))
          | select(($l | startswith($d)) and ($l | endswith($d)))
          | $l[$dn:(($l | length) - $dn)]
          | select(test("^[^*`]+:[0-9]+$")));
    def suppressed_scan:
      reduce (((. // "") | display_strip) | split("\n"))[] as $l
        ({declared: 0, entries: 0, unparsed: 0, inblock: false, depth: 0, fchar: "", flen: 0, list: []};
          ($l | capture("^[ \t]{0,3}(?<f>`{3,}|~{3,})(?<rest>.*)$") // null) as $fx
          | ($l | block_title) as $title
          | (($l | entry_token) // "") as $entry
          | if ($title | test("^(Suppressed comments|Previously missed)[ \t]*\\([0-9]+\\)$")) then
            .declared += ($title | capture("\\((?<n>[0-9]+)\\)") | .n | tonumber)
            | .inblock = true | .depth = 0 | .fchar = "" | .flen = 0
          elif ($title | test("^(Suppressed comments|Previously missed)([ \t]|$)")) then
            .unparsed += 1 | .inblock = true | .depth = 0 | .fchar = "" | .flen = 0
          elif .fchar != "" then
            if ($fx != null and ($fx.f[0:1] == .fchar)
                and (($fx.f | length) >= .flen) and ($fx.rest | test("^[ \t]*$")))
            then .fchar = "" | .flen = 0
            else . end
          elif $fx != null then
            .fchar = ($fx.f[0:1]) | .flen = ($fx.f | length)
          elif ($l | test("^<details([ \t>]|$)")) then
            if .inblock then .depth += 1 else . end
          elif ($l | test("^</details>")) then
            if .inblock and .depth > 0 then .depth -= 1
            else .inblock = false | .depth = 0 end
          elif ($l | test("^#{1,6}[ \t]")) then
            .inblock = false | .depth = 0
          elif .inblock and $entry != "" then
            .entries += 1 | .list += [$entry]
          else . end);
'

# The reader command is supplied by the caller: the gate keeps its retry
# reader, while the refresh runner uses gh api. Assigns the reviews array.
rg_load_reviews() {
raw_reviews="$("$@" "repos/$GH_REPO/pulls/$PR_NUMBER/reviews?per_page=100" --paginate)" || {
  rg_message error predicate-reviews-read "$PR_NUMBER" "::error::could not read reviews for PR #$PR_NUMBER" >&2
  exit 2
}
if [ -z "$raw_reviews" ]; then
  rg_message error predicate-reviews-empty "$PR_NUMBER" "::error::reviews read for PR #$PR_NUMBER produced zero bytes (broken read, not an empty page set)" >&2
  exit 2
fi
reviews="$(jq -s 'if (length > 0) and all(type == "array")
                  then add
                  else error("review pages are not arrays") end' <<<"$raw_reviews" 2>/dev/null)" || {
  rg_message error predicate-reviews-pages "$PR_NUMBER" "::error::reviews read for PR #$PR_NUMBER returned non-array pages or a vacuous body (broken read)" >&2
  exit 2
}
}
