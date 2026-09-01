- **Breaking:** the `block-repo-copy` and `block-unsafe-rm` hooks are one regex
  each and need `jq`. A copy is judged by the words a command spells — a `.git`
  or `target` source, a temp destination.
