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

# 7. Push PR
# usethis::pr_push()

# 8. Merge PR
# usethis::pr_merge_main()
# usethis::pr_finish()
