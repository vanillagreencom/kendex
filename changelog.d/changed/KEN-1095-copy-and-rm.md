- **Breaking:** the `block-repo-copy` and `block-unsafe-rm` hooks are one regex
  each and need `jq` and `cat`. A copy is judged by the words it spells: a
  `.git` or `target` source, a temp destination.
