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
release="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest")" ||
  fail release-read 'Could not read the latest release.'
version="$(jq -er '.tag_name | select(type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' <<<"$release")" ||
  fail release-version 'The latest release has no stable version tag.'
commit="$(curl -fsSL "https://api.github.com/repos/$repo/commits/$version")" ||
  fail commit-read 'Could not resolve the released tag to its commit.'
sha="$(jq -er '.sha | select(type == "string" and test("^[0-9a-f]{40}$"))' <<<"$commit")" ||
  fail commit-sha 'The released tag has no commit SHA.'
TMP="$(mktemp -d)" || fail scratch 'Could not create the installer directory.'
trap 'rm -rf -- "${TMP:?}"' EXIT
# Save the complete download before execution. A failed transfer must never
# execute a partial installer or fall back to another version.
curl -fsSL "https://raw.githubusercontent.com/$repo/$sha/install.sh" -o "$TMP/install.sh" ||
  fail installer-read 'Could not fetch the installer at the released commit.'
# install.sh picks a bin directory from PATH. Put the user directory first
# so CI never needs sudo and both callers know which binary they received.
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
sh "$TMP/install.sh" --version "$version" --cli-only ||
  fail installer-run 'The released installer failed.'
if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$HOME/.local/bin" >>"$GITHUB_PATH"
fi
printf 'kendex-install: version=%s commit=%s\n' "$version" "$sha"
