# shellcheck shell=bash
# Refresh fixtures mirror a release tree beside the consumer's installed skills.
. "$SKILL_DIR/tests/lib/sandbox.sh"
cp -R "$REFRESH_DIR" "$PRISTINE/refresh"
# Historical adopter controls retain their original sibling dependencies.
cp -R "$SKILL_DIR/scripts/." "$PRISTINE/refresh/"
export MSYS=winsymlinks:nativestrict
ln -s .agents/skills "$PRISTINE/skills"
[ -L "$PRISTINE/skills" ] || { echo 'refresh-fixture: skills=not-symlink' >&2; exit 1; }
commit "$PRISTINE"
