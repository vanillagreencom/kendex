- A project folder whose `.git` file names a git directory that no longer exists, a linked worktree whose main checkout was moved or deleted, is no longer read as a folder outside any repository. A command that asks git about such a folder, one that writes the project, `check` or `project list --json`, now reports that git could not read it, naming the missing git directory, where before it skipped the repository's own checks as if there were none.

  You do: in the main checkout run `git worktree repair <folder>`, or, where that checkout is gone, delete the folder's `.git` file.
