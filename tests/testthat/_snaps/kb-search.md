# snapshot: column names of kb_search() result

    Code
      names(res)
    Output
      [1] "path"       "heading"    "line_start" "score"      "snippet"   

# snapshot: error message when db_path missing

    Code
      kb_search("test query", "/definitely/does/not/exist.duckdb")
    Condition
      Error in `kb_search()`:
      x Index database '/definitely/does/not/exist.duckdb' not found.
      i Run `kb_index()` to build the index first.

# snapshot: error message when dir missing

    Code
      kb_index("/no/such/dir", db_path)
    Condition
      Error in `kb_index()`:
      x Directory '/no/such/dir' does not exist.
      i Supply a valid path to a knowledge-base directory.

