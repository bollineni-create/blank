#!/bin/sh
# Downloads the prebuilt llama.cpp XCFramework into LlamaKit/llama.xcframework and adds an
# iOS Simulator slice to it. XcodeGen runs this before generating the project (preGenCommand).
#
# The official release has device and Mac slices only, so the simulator slice is a stub
# library with the same headers and no code. LlamaKit compiles its engine out on the
# simulator, where Loom uses Apple's Foundation Models instead.
set -eu

RELEASE=b11565
CHECKSUM=865afb6d9a535b93445dcf89acd3f64002d609909faeeca4da75d83d19620584
URL="https://github.com/ggml-org/llama.cpp/releases/download/$RELEASE/llama-$RELEASE-xcframework.zip"
SIM=ios-arm64_x86_64-simulator

cd "$(dirname "$0")"
OUT=llama.xcframework
STAMP="$OUT/.release"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$RELEASE" ]; then
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Downloading llama.cpp $RELEASE XCFramework..."
curl -fL --progress-bar -o "$WORK/llama.zip" "$URL"
echo "$CHECKSUM  $WORK/llama.zip" | shasum -a 256 -c - >/dev/null
unzip -q "$WORK/llama.zip" -d "$WORK/unzipped"
SRC="$WORK/unzipped/build-apple/llama.xcframework"

# Simulator slice: the device framework's headers and module map around an empty library.
DEVICE="$SRC/ios-arm64/llama.framework"
FW="$SRC/$SIM/llama.framework"
mkdir -p "$FW"
cp -R "$DEVICE/Headers" "$DEVICE/Modules" "$FW/"
sed -e 's/iPhoneOS/iPhoneSimulator/' -e 's/iphoneos/iphonesimulator/g' "$DEVICE/Info.plist" > "$FW/Info.plist"
echo '// Stub: llama.cpp is not available in the iOS Simulator.' > "$WORK/stub.c"
for ARCH in arm64 x86_64; do
    xcrun --sdk iphonesimulator clang -dynamiclib -target "$ARCH-apple-ios17.0-simulator" \
        -install_name @rpath/llama.framework/llama -o "$WORK/llama-$ARCH" "$WORK/stub.c"
done
lipo -create "$WORK/llama-arm64" "$WORK/llama-x86_64" -output "$FW/llama"

PLIST="$SRC/Info.plist"
N=$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries" "$PLIST" | grep -c LibraryIdentifier)
/usr/libexec/PlistBuddy \
    -c "Add :AvailableLibraries:$N dict" \
    -c "Add :AvailableLibraries:$N:BinaryPath string llama.framework/llama" \
    -c "Add :AvailableLibraries:$N:LibraryIdentifier string $SIM" \
    -c "Add :AvailableLibraries:$N:LibraryPath string llama.framework" \
    -c "Add :AvailableLibraries:$N:SupportedArchitectures array" \
    -c "Add :AvailableLibraries:$N:SupportedArchitectures:0 string arm64" \
    -c "Add :AvailableLibraries:$N:SupportedArchitectures:1 string x86_64" \
    -c "Add :AvailableLibraries:$N:SupportedPlatform string ios" \
    -c "Add :AvailableLibraries:$N:SupportedPlatformVariant string simulator" \
    "$PLIST"

echo "$RELEASE" > "$SRC/.release"
rm -rf "$OUT"
mv "$SRC" "$OUT"
echo "llama.cpp $RELEASE ready in LlamaKit/$OUT"
