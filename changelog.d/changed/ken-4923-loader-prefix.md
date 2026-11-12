- `kendex marketplace check` refuses a settings template key that starts with `_kendex_`, the prefix the shell settings loader keeps for its own variables, and the app offers no field for one: every load of a file holding such a key fails.

  You do: rename any template key that starts with `_kendex_`.
