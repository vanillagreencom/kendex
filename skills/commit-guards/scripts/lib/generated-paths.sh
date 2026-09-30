# shellcheck shell=bash
# The render writer produces .kendex-generated.json; paths are literal files.
# Callers supply the inventory from the same state their scan measures.
# jq halts with 20 for the document count and 21 for the entry shape, and
# its halt text names what it read: the count, the type of a document that is
# not an array, or the index and the first 120 characters of the first entry
# the rule rejects. The shell reports the status as the stable refusal value
# and adds one fixed explanation per status. Any other status is jq's own parse
# or tool failure, reported with jq's text and a fix naming both remedies, the
# refresh and jq 1.7 or newer: jq 1.6 finds a NUL in every string and remaps
# halt_error statuses under -e, so it refuses every inventory with such a
# status. With no jq on PATH the status is the shell's command-not-found status.
# not-a-path: standalone inventory reader loads the shared message emitter.
# shellcheck source=messages.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/messages.sh"
GENERATED_PATHS=""
GENERATED_NL='
'
generated_paths_load() { # JSON — load the writer's exact paths, or refuse
  local output="" status=0 word reader explanation fix
  output="$(jq -ers '
    if length == 1 then .[0] else "\(length) JSON documents, not one\n" | halt_error(20) end
    | def path_string: type == "string" and length > 0
        and (contains("\n") or contains("\u0000") | not);
      def entry: if type == "string" then path_string
        elif type == "object" then
          keys == ["path", "template", "templateHash"]
          and (.path | path_string) and (.template | path_string)
          and (.templateHash | type == "string" and length == 71 and test("^sha256:[0-9a-f]{64}$"))
        else false end;
      if type == "array" then . else "the document is \(type), not an array\n" | halt_error(21) end
      | (first(range(length) as $i | select(.[$i] | entry | not) | $i) // null) as $bad
      | if $bad == null then map(if type == "string" then . else .path end) | join("\n")
        else "entry \($bad) fails the entry rule: \(.[$bad] | tojson | .[0:120])\n" | halt_error(21) end
  ' <<<"$1" 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    GENERATED_PATHS="$output"
    return 0
  fi
  GENERATED_PATHS=""
  fix="Run kendex refresh at the repository root, then stage .kendex-generated.json with the renders."
  if ! command -v jq >/dev/null 2>&1; then
    word="jq-missing"
    reader="no jq on PATH"
    explanation="Reading .kendex-generated.json needs jq."
    fix="Install jq, then run the check again."
  else
    reader="$(jq --version 2>&1)" || reader="jq, version unread (jq --version exit $?)"
    case "$status" in
      20)
        word="documents"
        explanation="The inventory must be exactly one JSON document."
        ;;
      21)
        word="entry-shape"
        explanation="The inventory is one array, and each entry is a non-empty path with no newline or NUL, or an adoption record with exactly path, template and a sha256 templateHash."
        ;;
      *)
        word="jq-error"
        explanation="jq could not read the inventory; the cause is jq's own text."
        fix="Run kendex refresh at the repository root, then stage .kendex-generated.json with the renders; the filter also needs jq 1.7 or newer, so install it if the jq named above is older."
        ;;
    esac
  fi
  gg_message inventory-status "$status" "status: $word, read by $reader
cause: ${output:-jq printed nothing}
$explanation
fix: $fix" >&2
  return 2
}

generated_path_contains() { # PATH — literal membership, never a glob
  case "$1" in "" | *"$GENERATED_NL"*) return 1 ;; esac
  case "$GENERATED_NL$GENERATED_PATHS$GENERATED_NL" in
    *"$GENERATED_NL$1$GENERATED_NL"*) return 0 ;;
  esac
  return 1
}
