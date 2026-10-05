# The skills each SKILL.md named on the command line requires: a
# `SKILL<TAB>NAME` row for each name its front matter declares under
# `dependencies.required`, SKILL being the directory that holds the file. The
# kendex engine reads the same key when it installs a skill
# (crates/core/src/source/browse/deps.rs). Every SKILL.md here spells it as a
# two-space `required:` or `optional:` key holding an inline list of bare
# names. Anything else this reader meets under `dependencies:` prints `?` and
# its file, a name that is not bare prints `?` too, and each caller refuses
# both rather than read them as no dependency. tools/ci-job-set follows the
# rows to select shards; tools/shipped-refs judges a link between skills by
# them.
FNR == 1 { front = ($0 == "---"); deps = 0; skill = FILENAME; sub(/\/SKILL\.md$/, "", skill); sub(/^.*\//, "", skill); next }
!front { next }
$0 == "---" { front = 0; next }
/^[^ ]/ {
  deps = ($0 == "dependencies:")
  if (!deps && index($0, "dependencies:") == 1) print "?\t" FILENAME
  next
}
!deps { next }
/^  optional:/ { next }
!/^  required:/ { print "?\t" FILENAME; next }
{
  list = $0
  sub(/^  required:[ ]*/, "", list)
  if (substr(list, 1, 1) != "[" || substr(list, length(list)) != "]" || index(substr(list, 2, length(list) - 2), "]") > 0) { print "?\t" FILENAME; next }
  gsub(/[][ ]/, "", list)
  n = split(list, names, ",")
  for (i = 1; i <= n; i++) {
    if (names[i] !~ /^[a-z0-9-]+$/) { print "?\t" FILENAME; continue }
    print skill "\t" names[i]
  }
}
