# shellcheck shell=bash
# The mail pass owns one snapshot per provider. Its readers never reconnect
# for a missing row or a failed batch: neither is evidence of an absent file.
LANE_HOST_READ_FILE=""
lane_host_cached_path() { # DIRECTORY ITEM PATH ERRF: provider file status
  local item path status number found=0
  LANE_HOST_READ_FILE=""
  if [[ -s "$1/failed" ]]; then
    cat -- "$1/error" >"$4" || return 1
    read -r status <"$1/failed" || return 1
    return "$status"
  fi
  while IFS=$'\t' read -r item path status number; do
    [[ "$item" == "$2" && "$path" == "$3" ]] || continue
    found=1
    break
  done <"$1/index" 2>"$4" || return 1
  if [[ "$found" -eq 0 ]]; then
    printf 'lane-host-read: row-missing item=%s path=%s\n' "$2" "$3" >"$4"
    return 1
  fi
  [[ "$status" -eq 0 ]] || {
    cat -- "$1/$number.error" >"$4" || return 1
    printf 'lane-host-read: file-failed item=%s path=%s status=%s\n' "$2" "$3" "$status" >>"$4"
    return "$status"
  }
  LANE_HOST_READ_FILE="$1/$number"
}
lane_host_cached_read() { # DIRECTORY ITEM PATH DEST ERRF: provider file status
  lane_host_cached_path "$1" "$2" "$3" "$5" || return "$?"
  cat -- "$LANE_HOST_READ_FILE" >"$4" 2>"$5"
}
