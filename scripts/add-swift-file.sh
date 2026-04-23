#!/bin/bash
# scripts/add-swift-file.sh — Register a new Swift file in GhosttyTabs.xcodeproj.
#
# Wrapper around scripts/add-swift-file.rb that locates the cocoapods-bundled
# `xcodeproj` Ruby gem (shipped with Homebrew cocoapods) and runs the impl
# under that GEM_HOME so `require 'xcodeproj'` resolves.
#
# See add-swift-file.rb for usage and behaviour.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMPL="${SCRIPT_DIR}/add-swift-file.rb"

if [ ! -f "$IMPL" ]; then
  echo "error: ${IMPL} not found" >&2
  exit 1
fi

if ! command -v ruby >/dev/null 2>&1; then
  echo "error: ruby not found in PATH" >&2
  exit 1
fi

XCODEPROJ_SHIM="/opt/homebrew/bin/xcodeproj"
if [ ! -x "$XCODEPROJ_SHIM" ]; then
  echo "error: Homebrew cocoapods shim not found at ${XCODEPROJ_SHIM}" >&2
  echo "hint: \`brew install cocoapods\` installs the required \`xcodeproj\` Ruby gem." >&2
  exit 1
fi

GEM_HOME_VALUE="$(sed -n 's/.*GEM_HOME="\([^"]*\)".*/\1/p' "$XCODEPROJ_SHIM" | head -n 1)"
if [ -z "$GEM_HOME_VALUE" ]; then
  echo "error: could not derive GEM_HOME from ${XCODEPROJ_SHIM}" >&2
  exit 1
fi

export GEM_HOME="$GEM_HOME_VALUE"
exec ruby "$IMPL" "$@"
