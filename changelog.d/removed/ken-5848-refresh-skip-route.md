- Consumer refresh no longer skips the render on a run whose inputs match a saved record. Every scheduled, dispatched and manual Refresh kendex run takes the full refresh path, and no run saves the current-inputs record artifact. The shared release workflow no longer outputs `route`, and the shipped caller template no longer reads it and grants its token only the permissions its jobs use: Actions write for the release job and Contents read for the refresh job.

  You do: nothing
