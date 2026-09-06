# shellcheck shell=bash
# The render writer produces .kendex-generated.json; paths are literal files.
# Callers supply the inventory from the same state their scan measures.
GENERATED_PATHS=""
GENERATED_NL='
'
generated_paths_load() { # JSON — load the writer's exact paths, or refuse
  GENERATED_PATHS="$(jq -ers '
    if length == 1 then .[0] else error("expected one inventory") end
    | if type == "array" and all(.[];
        type == "string" and length > 0
        and (contains("\n") or contains("\u0000") | not))
      then join("\n")
      else error("expected an array of paths without newline or NUL") end
  ' <<<"$1")" || {
    echo '::error::generated paths: cannot read .kendex-generated.json; jq is required; install or refresh kendex at the Git repository root in the main checkout and stage the inventory with the renders' >&2
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
