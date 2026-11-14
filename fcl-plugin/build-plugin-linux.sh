#!/usr/bin/env bash
# Build the FCL renderer plugin APK on Linux / GitHub Actions.
# LGPL-3.0-or-later
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$ROOT/fcl-plugin"
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
NDK_VERSION="27.2.12479018"
BUILD_TOOLS_VERSION="34.0.0"
ANDROID_PLATFORM="android-26"

if [[ -z "$SDK_ROOT" ]]; then
  echo "ANDROID_HOME or ANDROID_SDK_ROOT must point to the Android SDK." >&2
  exit 1
fi

NDK="$SDK_ROOT/ndk/$NDK_VERSION"
TOOLCHAIN="$NDK/build/cmake/android.toolchain.cmake"
BUILD_TOOLS="$SDK_ROOT/build-tools/$BUILD_TOOLS_VERSION"
ANDROID_JAR="$SDK_ROOT/platforms/android-34/android.jar"
AAPT2="$BUILD_TOOLS/aapt2"
ZIPALIGN="$BUILD_TOOLS/zipalign"
APKSIGNER="$BUILD_TOOLS/apksigner"
D8="$BUILD_TOOLS/d8"

for path in "$TOOLCHAIN" "$ANDROID_JAR" "$AAPT2" "$ZIPALIGN" "$APKSIGNER" "$D8"; do
  if [[ ! -e "$path" ]]; then
    echo "Required Android build tool not found: $path" >&2
    exit 1
  fi
done
for tool in cmake ninja javac jar keytool zip unzip; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Required command not found on PATH: $tool" >&2
    exit 1
  }
done

WORK="$PLUGIN_DIR/build-linux"
OUT_DIR="$ROOT/build/plugin"
rm -rf "$WORK"
mkdir -p "$WORK/classes" "$WORK/dex" "$WORK/apk" "$WORK/logs" "$OUT_DIR"

ABIS=("arm64-v8a" "armeabi-v7a")

# 1. Build the native renderer for both Android ARM ABIs.
for ABI in "${ABIS[@]}"; do
  echo "=== Building native library: $ABI ==="
  NATIVE_BUILD="$ROOT/native/build/$ABI"
  cmake -S "$ROOT/native" -B "$NATIVE_BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DCMAKE_MAKE_PROGRAM="$(command -v ninja)" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="$ANDROID_PLATFORM" \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "$NATIVE_BUILD" --parallel

  SO="$NATIVE_BUILD/libgl_gles.so"
  [[ -s "$SO" ]] || { echo "Native build did not produce $SO" >&2; exit 1; }
  mkdir -p "$ROOT/build/native/$ABI" "$WORK/apk/lib/$ABI"
  cp "$SO" "$ROOT/build/native/$ABI/libgl_gles.so"
  cp "$SO" "$WORK/apk/lib/$ABI/libgl_gles.so"
done

# 2. Compile Android resources.
echo "=== Compiling Android resources ==="
"$AAPT2" compile --dir "$PLUGIN_DIR/res" -o "$WORK/resources.zip" \
  >"$WORK/logs/aapt2-compile.log" 2>&1

# 3. Link the manifest and resources into the base APK.
echo "=== Linking Android manifest/resources ==="
"$AAPT2" link \
  -o "$WORK/base.apk" \
  -I "$ANDROID_JAR" \
  --manifest "$PLUGIN_DIR/AndroidManifest.xml" \
  -R "$WORK/resources.zip" \
  --min-sdk-version 26 \
  --target-sdk-version 34 \
  --version-code 1 \
  --version-name 1.0.0 \
  --auto-add-overlay \
  >"$WORK/logs/aapt2-link.log" 2>&1

# 4. Compile the small Java host Activity and convert it to DEX.
echo "=== Compiling Java Activity ==="
mapfile -t JAVA_SOURCES < <(find "$PLUGIN_DIR/src" -type f -name '*.java' -print | sort)
if [[ ${#JAVA_SOURCES[@]} -eq 0 ]]; then
  echo "No Java sources found in $PLUGIN_DIR/src" >&2
  exit 1
fi
javac -source 8 -target 8 -nowarn \
  -bootclasspath "$ANDROID_JAR" \
  -d "$WORK/classes" \
  "${JAVA_SOURCES[@]}" \
  >"$WORK/logs/javac.log" 2>&1
jar cf "$WORK/classes.jar" -C "$WORK/classes" . \
  >"$WORK/logs/jar.log" 2>&1
"$D8" --lib "$ANDROID_JAR" --min-api 26 \
  --output "$WORK/dex" "$WORK/classes.jar" \
  >"$WORK/logs/d8.log" 2>&1
[[ -s "$WORK/dex/classes.dex" ]] || {
  echo "D8 did not produce classes.dex" >&2
  exit 1
}

# 5. Add classes.dex and the uncompressed native libraries to the APK.
echo "=== Assembling APK ==="
UNSIGNED="$WORK/unsigned.apk"
cp "$WORK/base.apk" "$UNSIGNED"
(
  cd "$WORK/dex"
  zip -q "$UNSIGNED" classes.dex
)
(
  cd "$WORK/apk"
  zip -0 -q "$UNSIGNED" \
    lib/arm64-v8a/libgl_gles.so \
    lib/armeabi-v7a/libgl_gles.so
)

# 6. Align and sign with a generated debug key (side-load/test build).
echo "=== Aligning and signing APK ==="
KEYSTORE="$WORK/debug.keystore"
keytool -genkeypair -noprompt \
  -keystore "$KEYSTORE" \
  -storepass android \
  -keypass android \
  -alias glesmod \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -dname "CN=GLES Mod Renderer, OU=dev, O=glesmod, L=dev, S=dev, C=CN" \
  >"$WORK/logs/keytool.log" 2>&1

ALIGNED="$WORK/aligned.apk"
APK="$OUT_DIR/glesmod-renderer-plugin.apk"
"$ZIPALIGN" -f -p 4 "$UNSIGNED" "$ALIGNED"
"$APKSIGNER" sign \
  --ks "$KEYSTORE" \
  --ks-pass pass:android \
  --key-pass pass:android \
  --ks-key-alias glesmod \
  --out "$APK" \
  "$ALIGNED" \
  >"$WORK/logs/apksigner.log" 2>&1
"$APKSIGNER" verify --verbose "$APK" \
  >"$WORK/logs/apksigner-verify.log" 2>&1
"$ZIPALIGN" -c -p 4 "$APK"

# 7. Fail the build if FCL-required metadata or either ABI library is missing.
"$AAPT2" dump xmltree --file AndroidManifest.xml "$APK" \
  >"$WORK/logs/manifest-dump.txt" 2>&1
MANIFEST_DUMP="$WORK/logs/manifest-dump.txt"
for field in fclPlugin renderer des boatEnv pojavEnv; do
  grep -Fq "\"$field\"" "$MANIFEST_DUMP" || {
    echo "FCL metadata field missing from compiled APK: $field" >&2
    exit 1
  }
done
grep -Fq 'LIBGL_ES=3' "$MANIFEST_DUMP" || {
  echo "pojavEnv is missing LIBGL_ES=3" >&2
  exit 1
}
grep -Fq 'POJAV_RENDERER=opengles' "$MANIFEST_DUMP" || {
  echo "pojavEnv is missing POJAV_RENDERER=opengles" >&2
  exit 1
}

APK_ENTRIES="$(unzip -Z1 "$APK")"
for ABI in "${ABIS[@]}"; do
  ENTRY="lib/$ABI/libgl_gles.so"
  grep -Fxq "$ENTRY" <<<"$APK_ENTRIES" || {
    echo "APK is missing $ENTRY" >&2
    exit 1
  }
done

echo ""
echo "FCL plugin APK built and verified: $APK"
ls -lh "$APK"
echo "Included ABIs: ${ABIS[*]}"
