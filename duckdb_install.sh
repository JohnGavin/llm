#!/bin/bash
# DuckDB dplyr Extension Installation Script

set -e

PLATFORM=""
case "$(uname -s)" in
    Linux*)     PLATFORM="linux-x86_64";;
    Darwin*)
        case "$(uname -m)" in
            arm64)  PLATFORM="macos-arm64";;
            *)      PLATFORM="macos-x86_64";;
        esac;;
    CYGWIN*|MINGW*|MSYS*) PLATFORM="windows-x86_64";;
    *)          echo "Unsupported platform"; exit 1;;
esac

if [[ -z "${DUCKDB_VERSION:-}" ]]; then
    echo "This release contains DuckDB-version-specific binaries."
    echo "Set DUCKDB_VERSION to the exact DuckDB version you are using (e.g., v1.4.0 or v1.4.4)."
    echo ""
    echo "Available binaries for platform $PLATFORM:"
    ls -1 "dplyr-"*"-${PLATFORM}.duckdb_extension" 2>/dev/null || ls -1 *.duckdb_extension
    exit 1
fi

EXTENSION_FILE="dplyr-${DUCKDB_VERSION}-${PLATFORM}.duckdb_extension"

if [[ ! -f "$EXTENSION_FILE" ]]; then
    echo "Extension file for platform $PLATFORM and DuckDB $DUCKDB_VERSION not found!"
    echo "Available binaries for platform $PLATFORM:"
    ls -1 "dplyr-"*"-${PLATFORM}.duckdb_extension" 2>/dev/null || ls -1 *.duckdb_extension
    exit 1
fi

echo "Installing DuckDB dplyr extension for $PLATFORM..."
echo "Extension file: $EXTENSION_FILE"
echo ""
echo "To use the extension, load it in DuckDB:"
echo "  LOAD '$(pwd)/$EXTENSION_FILE';"
echo ""
echo "Installation completed successfully!"
