#!/usr/bin/env bash
# The runner's explicit marker records a timeout or unavailable host check.
# Foreground records use the same verdict rule without changing their raw exit.

validation_verdict() { # SENTINEL-LINE
  case "$1" in
    *" verdict=no-verdict cause=host") printf 'no-verdict\n' ;;
    *" verdict=no-verdict") printf 'no-verdict\n' ;;
    "guard-exit=0 "*) printf 'pass\n' ;;
    *) printf 'FAILING\n' ;;
  esac
}
