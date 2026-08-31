- Quote characters and bash's own metacharacters come out of a command before
  its words are read, so `git commit "--no-verify"` and `true;git commit -n`
  are refused as the bare flag is.
