#!/usr/bin/env bash
# The refresh and catalog-check workflows install one released engine. GitHub's
# releases/latest response selects the tag; the commits API resolves that tag
# to a commit, including annotated tags. target_commitish can name a branch.
# Report protocol: kendex-install: version=TAG commit=SHA on success, or
# kendex-install: cause=KEY on failure. The following English is not parsed.
set -euo pipefail

fail() {
  printf 'kendex-install: cause=%s\n%s\n' "$1" "$2" >&2
  exit 1
}
repo=vanillagreencom/kendex
# Only the supplied read-only workflow token authorizes API reads. GH_TOKEN
# may hold an app credential and must not reach any download or installer.
github_api() { # repository-relative API path
  local args=(-fsSL)
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  env -u GH_TOKEN -u GITHUB_TOKEN curl "${args[@]}" "https://api.github.com/repos/$repo/$1"
}
release="$(github_api releases/latest)" ||
  fail release-read 'Could not read the latest release.'
version="$(jq -er '.tag_name | select(type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' <<<"$release")" ||
  fail release-version 'The latest release has no stable version tag.'
commit="$(github_api "commits/$version")" ||
  fail commit-read 'Could not resolve the released tag to its commit.'
sha="$(jq -er '.sha | select(type == "string" and test("^[0-9a-f]{40}$"))' <<<"$commit")" ||
  fail commit-sha 'The released tag has no commit SHA.'
TMP="$(mktemp -d)" || fail scratch 'Could not create the installer directory.'
trap 'rm -rf -- "${TMP:?}"' EXIT
# Save the complete download before execution. A failed transfer must never
# execute a partial installer or fall back to another version.
env -u GH_TOKEN -u GITHUB_TOKEN curl -fsSL "https://raw.githubusercontent.com/$repo/$sha/install.sh" -o "$TMP/install.sh" ||
  fail installer-read 'Could not fetch the installer at the released commit.'
# install.sh picks a bin directory from PATH. Put the user directory first
# so CI never needs sudo and both callers know which binary they received.
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
env -u GH_TOKEN -u GITHUB_TOKEN sh "$TMP/install.sh" --version "$version" --cli-only ||
  fail installer-run 'The released installer failed.'
if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$HOME/.local/bin" >>"$GITHUB_PATH"
fi
printf 'kendex-install: version=%s commit=%s\n' "$version" "$sha"
