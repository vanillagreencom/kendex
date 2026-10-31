#!/usr/bin/env bash
# Sourced first by a suite's gh stub: the credential gh would use, so a row can
# hold a stale environment token beside a working keyring login. gh prefers
# GH_TOKEN, then GITHUB_TOKEN, then its keyring login. A token starting
# ghp_stale, or an unprefixed placeholder starting stale, is one GitHub
# refuses; GH_KEYRING=none is a host with no keyring login. A refused credential fails every command with gh's 401. When
# GH_CREDENTIAL_LOG is set, each command appends "<credential> <argv>" to it.
gh_credential="${GH_TOKEN:-${GITHUB_TOKEN:-keyring}}"
[[ -z "${GH_CREDENTIAL_LOG:-}" ]] || printf '%s %s\n' "$gh_credential" "$*" >>"$GH_CREDENTIAL_LOG"
case "$gh_credential" in
  ghp_stale* | stale*)
    echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" >&2
    exit 1
    ;;
  keyring)
    if [[ "${GH_KEYRING:-}" == none ]]; then
      echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2
      exit 4
    fi
    ;;
esac
unset gh_credential
