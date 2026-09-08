# shellcheck shell=bash
# The render writer produces .kendex-generated.json; paths are literal files.
# Callers supply the inventory from the same state their scan measures.
# jq returns 20 for document count and 21 for entry shape; the shell reports
# that status as the stable refusal value. Parse/tool failures retain their status.
# not-a-path: standalone inventory reader loads the shared message emitter.
# shellcheck source=messages.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/messages.sh"
GENERATED_PATHS=""
GENERATED_NL='
'
generated_paths_load() { # JSON — load the writer's exact paths, or refuse
  GENERATED_PATHS="$(jq -ers '
    if length == 1 then .[0] else "" | halt_error(20) end
    | if type == "array" and all(.[];
        type == "string" and length > 0
        and (contains("\n") or contains("\u0000") | not))
      then join("\n")
      else "" | halt_error(21) end
  ' <<<"$1")" || {
    gg_message inventory-status "$?" "Cannot read .kendex-generated.json. Install jq or refresh and stage the inventory." >&2
    return 2
  }
}

generated_path_contains() { # PATH — literal membership, never a glob
  case "$1" in "" | *"$GENERATED_NL"*) return 1 ;; esac
  case "$GENERATED_NL$GENERATED_PATHS$GENERATED_NL" in
    *"$GENERATED_NL$1$GENERATED_NL"*) return 0 ;;
  esac
  return 1
}
