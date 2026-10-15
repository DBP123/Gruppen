# Sourced by build.sh and Tests/run.sh: picks the SDK to compile against and
# sets $SDK.
#
# A macOS 26 SDK, by choice. From the macOS 27 SDK on, SwiftUI's @State is a
# macro, and its implementation (libSwiftUIMacros) ships with Xcode but not
# with the Command Line Tools — so against that SDK every @State in the app
# fails with "plugin for module 'SwiftUIMacros' not found". The 26 SDK builds
# the same app with no plugin, and the binary runs on macOS 27 unchanged.
#
# Falls back to the default SDK only when it can actually build SwiftUI: a
# full Xcode is selected, or the tools carry the plugin. Otherwise it stops
# with the reason rather than a few hundred compiler errors.

SDK_ROOT="$(dirname "$(xcrun --show-sdk-path)")"
SDK="$(ls -d "$SDK_ROOT"/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)"

if [ -z "$SDK" ]; then
    TOOLS="$(xcode-select -p)"
    if [ -e "$TOOLS/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ] \
        || [ -e "$TOOLS/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
        SDK="$(xcrun --show-sdk-path)"
    else
        echo "error: no macOS 26 SDK in $SDK_ROOT, and these tools cannot build SwiftUI against" >&2
        echo "       $(basename "$(xcrun --show-sdk-path)") (no SwiftUIMacros plugin)." >&2
        echo "       Install Xcode and run 'sudo xcode-select -s /Applications/Xcode.app', or" >&2
        echo "       reinstall Command Line Tools that include a macOS 26 SDK." >&2
        exit 1
    fi
fi
