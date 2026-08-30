- Quote characters and redirection operators come out of a command before its
  words are read, so `git commit "--no-verify"` and `git commit>/dev/null -n`
  are refused as the bare flag is.
