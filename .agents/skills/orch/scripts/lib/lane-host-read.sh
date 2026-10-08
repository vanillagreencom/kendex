# shellcheck shell=bash
# The mail pass owns one snapshot per provider. Its readers never reconnect
# for a missing row or a failed batch: neither is evidence of an absent file.
lane_host_cached_read() { # DIRECTORY ITEM PATH DEST ERRF: provider file status
  local row status number
  if [[ -s "$1/failed" ]]; then
    cat -- "$1/error" >"$5" || return 1
    read -r status <"$1/failed" || return 1
    return "$status"
  fi
  row="$(awk -F '\t' -v item="$2" -v path="$3" '$1 == item && $2 == path { print $3 " " $4 }' "$1/index" 2>"$5")" || return 1
  if [[ -z "$row" ]]; then
    printf 'lane-host-read: row-missing item=%s path=%s\n' "$2" "$3" >"$5"
    return 1
  fi
  read -r status number <<<"$row"
  [[ "$status" -eq 0 ]] || {
    cat -- "$1/$number.error" >"$5" || return 1
    printf 'lane-host-read: file-failed item=%s path=%s status=%s\n' "$2" "$3" "$status" >>"$5"
    return "$status"
  }
  cat -- "$1/$number" >"$4" 2>"$5"
}
