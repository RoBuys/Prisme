#!/bin/zsh
# Runs the test suite (Swift Testing).
set -e
cd "$(dirname "$0")"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
[ -d "$SDK" ] && export SDKROOT="$SDK"   # SwiftUI macros need full Xcode on newer SDKs
swift test "$@"
