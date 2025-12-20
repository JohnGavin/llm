# Fix Issue 7: Ensure Codex wrapper is on PATH in nix shells

# Issue: https://github.com/JohnGavin/llm/issues/7

# 1. Create issue (already done)
if (FALSE) {
  gh::gh(
    "POST /repos/JohnGavin/llm/issues",
    title = "Ensure Codex wrapper is on PATH in nix shells",
    body = "Add project bin/codex wrapper and ensure nix shellHook prepends ~/docs_gh/llm/bin to PATH so Codex preflight uses Nix tools."
  )
}

# 2. Create dev branch (already done)
if (FALSE) {
  options(rlang_interactive = TRUE)
  env <- asNamespace("usethis")
  unlockBinding("ui_yep", env)
  assign("ui_yep", function(...) TRUE, envir = env)
  usethis::pr_init("fix-issue-7-codex-path")
}

# 3. Changes made
# - Add PATH export to shell_hook in default.R
# - Add bin/codex wrapper script

# 4. Regenerate default.nix
# system("/Users/johngavin/docs_gh/llm/default.sh")

# 5. Run checks (not applicable: repo is not an R package)

# 6. Push to cachix (not applicable: no build artifacts for this repo)

# 7. Create PR
# gh::gh(
#   "POST /repos/JohnGavin/llm/pulls",
#   title = "Fix issue 7: codex PATH wrapper",
#   head = "JohnGavin:fix-issue-7-codex-path",
#   base = "main",
#   body = "Fixes #7. Adds repo bin/codex wrapper and updates nix shellHook PATH."
# )

# 8. Merge PR
# env <- asNamespace("usethis")
# unlockBinding("ui_yep", env)
# assign("ui_yep", function(...) TRUE, envir = env)
# usethis::pr_merge_main()
# usethis::pr_finish()
# gh::gh("PUT /repos/JohnGavin/llm/pulls/8/merge")
