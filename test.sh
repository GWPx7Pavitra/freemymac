#!/bin/zsh
# Runs the tests with only Apple's Command Line Tools installed. Without full
# Xcode, Swift Testing's macro plugin has to be pointed at explicitly.
set -euo pipefail
cd "$(dirname "$0")"
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
