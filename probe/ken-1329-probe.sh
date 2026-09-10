#!/usr/bin/env bash
# KEN-1329 probe: throwaway file on a throwaway branch. Never merged.
set -euo pipefail

probe_sum() {
  local total=0 n
  for n in "$@"; do
    total=$((total + n))
  done
  printf "%s\n" "$total"
}

probe_mean() {
  local count=$#
  local sum
  sum=$(probe_sum "$@")
  printf "%s\n" $((sum / count))
}

probe_mean $@
