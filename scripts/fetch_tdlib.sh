#!/usr/bin/env bash
# Downloads the prebuilt libtdjson.so binaries into android/app/src/main/jniLibs.
#
# The .so files are not kept in git (81 MB); this script reproduces them
# byte-for-byte and refuses to install anything that does not match the
# recorded SHA-256.
set -euo pipefail

VERSION="v1.8.65"
ARCHIVE_SHA256="eb777d3e7baedeb02871c691b2090daa1bc51baf9215a81bc55bf54edb76df2b"
URL="https://github.com/up9cloud/android-libtdjson/releases/download/${VERSION}/jniLibs.tar.gz"

# Flutter builds these three ABIs; x86 exists in the archive but is unused.
ABIS=(arm64-v8a armeabi-v7a x86_64)

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$root/android/app/src/main/jniLibs"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Downloading TDLib ${VERSION}..."
curl -fL --retry 3 -o "$work/jniLibs.tar.gz" "$URL"

actual="$(sha256sum "$work/jniLibs.tar.gz" | cut -d' ' -f1)"
if [ "$actual" != "$ARCHIVE_SHA256" ]; then
  echo "SHA-256 mismatch!" >&2
  echo "  expected $ARCHIVE_SHA256" >&2
  echo "  actual   $actual" >&2
  exit 1
fi
echo "SHA-256 verified."

tar -xzf "$work/jniLibs.tar.gz" -C "$work"

for abi in "${ABIS[@]}"; do
  mkdir -p "$dest/$abi"
  cp "$work/jniLibs/$abi/libtdjson.so" "$dest/$abi/libtdjson.so"
  echo "  installed $abi"
done

echo "Done. libtdjson.so is in place for: ${ABIS[*]}"
