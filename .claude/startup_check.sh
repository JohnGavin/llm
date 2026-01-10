#!/bin/bash
echo '🔍 Checking Environment...'
git status -s
if [[ -n \"$IN_NIX_SHELL\" ]]; then
    EXPECTED=$(nix-instantiate default.nix 2>/dev/null | cut -d'-' -f1 | rev | cut -c1-10 | rev)
    echo \"✅ Nix Shell Active [Hash: $EXPECTED]\"
  else
    echo \"⚠️  WARNING: Not in Nix Shell. Run 'nix-shell' to sync.\"
fi

if [[ -n "$IN_NIX_SHELL" ]]; then
  echo "Nix Environment: OK"
else
  echo "Warning: No Nix shell detected."
fi

if [ "$IN_NIX_SHELL" != "impure" ] && [ "$IN_NIX_SHELL" != "pure" ]; then 
  echo "⚠️ NOT IN NIX SHELL"; 
else 
  CURRENT_DRV=$(echo $SHLVL); # Simple check, or use a more robust hash comparison:
  EXPECTED_HASH=$(nix-instantiate default.nix 2>/dev/null);
  echo "✅ Nix Shell Active (Hash: ${EXPECTED_HASH: -10})";
fi

