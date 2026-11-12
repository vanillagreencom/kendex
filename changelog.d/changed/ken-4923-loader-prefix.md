- `kendex marketplace check` refuses a settings template key that starts with `_kendex_`, the prefix the shell settings loader keeps for its own variables, and the app offers no field for one: every load of a file holding such a key fails. The Bash loader also refuses assignments to integer, array or name-reference destinations so settings values stay data, with a file, line and key diagnostic.

  You do: rename any template key that starts with `_kendex_`, and use ordinary scalar variables for settings destinations.
