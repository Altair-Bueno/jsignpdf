#!/usr/bin/env bash
#
# Builds a macOS arm64 DMG installer for JSignPdf using jpackage.
#
# Produces one artifact in distribution/target/upload/:
#   JSignPdf-<version>-mac-aarch64.dmg
#
# Prerequisites on the build machine:
#   * macOS on Apple Silicon (arm64)
#   * JDK 17+ on PATH (provides jpackage)
#   * jsignpdf and installcert modules already built:
#       mvn -B -DskipTests -pl jsignpdf,installcert -am package
#
# Usage:
#   distribution/macos/build-macos-installers.sh --version <version>
#
# Note on JavaFX classifier filtering: the project pom declares JavaFX
# classifier deps for win/linux/mac/mac-aarch64 to support cross-platform
# fat-jar builds. For a host-platform jpackage build we must drop the
# foreign-platform classifier jars from the staging dir, otherwise
# javafx.NativeLibLoader can resolve the wrong-arch dylib at runtime.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$VERSION" ]] || die "--version is required"
[[ "$(uname -s)" == "Darwin" ]] || die "this script must run on macOS"
[[ "$(uname -m)" == "arm64" ]] || die "this script must run on Apple Silicon (got $(uname -m))"
command -v jpackage >/dev/null || die "jpackage not found on PATH (install JDK 17+)"
command -v iconutil >/dev/null || die "iconutil not found (should be in /usr/bin on macOS)"
command -v sips >/dev/null     || die "sips not found (should be in /usr/bin on macOS)"

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TARGET=$ROOT/distribution/target
STAGING=$TARGET/jpackage-staging-mac
GENERATED=$TARGET/jpackage-generated-mac
OUT=$TARGET/jpackage-out-mac
UPLOAD=$TARGET/upload
JPKG_CFG=$ROOT/distribution/jpackage
ICON_SRC=$ROOT/distribution/linux/flatpak/jsignpdf.png

# jpackage --app-version accepts only numeric MAJOR[.MINOR[.MICRO]]. Strip any
# non-numeric suffix (e.g. "-RC1", "-SNAPSHOT") and keep up to three numeric
# components. $VERSION itself is preserved for release-tag-aligned filenames.
APP_VERSION=$(echo "$VERSION" \
    | sed -E 's/[^0-9.].*$//' \
    | awk -F. '{
        n = (NF > 3 ? 3 : NF);
        for (i = 1; i <= n; i++) printf("%s%s", (i>1?".":""), $i);
        printf("\n");
      }')
[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
    || die "cannot derive jpackage --app-version from '$VERSION'"

echo "JSignPdf jpackage build (macOS arm64)"
echo "  version    : $VERSION"
echo "  appVersion : $APP_VERSION"
echo "  root       : $ROOT"

THIN_JAR=$ROOT/jsignpdf/target/jsignpdf-$VERSION.jar
DEP_DIR=$ROOT/jsignpdf/target/dependency
INSTALLCERT_JAR=$ROOT/installcert/target/installcert-$VERSION.jar

[[ -f "$THIN_JAR" ]] || die "missing $THIN_JAR — run 'mvn -B -DskipTests -pl jsignpdf,installcert -am package' first"
[[ -d "$DEP_DIR" ]] || die "missing $DEP_DIR — run 'mvn -B -DskipTests -pl jsignpdf,installcert -am package' first"
[[ -f "$INSTALLCERT_JAR" ]] || die "missing $INSTALLCERT_JAR"

rm -rf "$STAGING" "$GENERATED" "$OUT"
mkdir -p "$STAGING" "$GENERATED" "$OUT" "$UPLOAD"

# Drop old artifacts from repeat local runs so a stale build doesn't sit
# alongside the new one.
find "$UPLOAD" -maxdepth 1 -type f -name 'JSignPdf-*-mac-aarch64.dmg' -delete 2>/dev/null || true

# Stage payload: thin app jar + InstallCert + filtered dependency jars.
cp "$THIN_JAR" "$STAGING/JSignPdf.jar"
cp "$INSTALLCERT_JAR" "$STAGING/InstallCert.jar"

# Copy deps but exclude wrong-platform JavaFX classifier jars. We keep:
#   * platform-independent jars  (e.g. javafx-controls-21.0.7.jar)
#   * the matching arm64 classifier (e.g. javafx-graphics-21.0.7-mac-aarch64.jar)
# and drop *-win.jar / *-linux.jar / *-mac.jar (x86_64 mac).
shopt -s nullglob
for f in "$DEP_DIR"/*.jar; do
    name=$(basename "$f")
    case "$name" in
        *-win.jar|*-linux.jar|*-mac.jar) continue ;;
    esac
    cp "$f" "$STAGING/"
done
shopt -u nullglob

# Generate a .icns from the 512x512 flatpak PNG. macOS expects an iconset
# directory with multiple sizes; iconutil compiles it to .icns.
[[ -f "$ICON_SRC" ]] || die "missing icon source: $ICON_SRC"
ICONSET=$GENERATED/JSignPdf.iconset
ICON_ICNS=$GENERATED/JSignPdf.icns
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for spec in "16 icon_16x16.png"          "32 icon_16x16@2x.png" \
            "32 icon_32x32.png"          "64 icon_32x32@2x.png" \
            "128 icon_128x128.png"       "256 icon_128x128@2x.png" \
            "256 icon_256x256.png"       "512 icon_256x256@2x.png" \
            "512 icon_512x512.png"; do
    size=${spec%% *}
    fname=${spec##* }
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/$fname" >/dev/null
done
iconutil -c icns -o "$ICON_ICNS" "$ICONSET"

# Read shared JVM options from the single source of truth.
COMMON_JVM_OPTIONS_FILE=$JPKG_CFG/common-jvm-options.txt
[[ -f "$COMMON_JVM_OPTIONS_FILE" ]] || die "missing $COMMON_JVM_OPTIONS_FILE"
COMMON_JVM_OPTIONS=()
while IFS= read -r line; do
    line=$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    COMMON_JVM_OPTIONS+=("$line")
done < "$COMMON_JVM_OPTIONS_FILE"

# Main launcher gets the shared opts via repeated --java-options.
MAIN_JVM_ARGS=()
for opt in "${COMMON_JVM_OPTIONS[@]}"; do
    MAIN_JVM_ARGS+=( --java-options "$opt" )
done

# Generate add-launcher properties files. We use platform-neutral keys only
# (no win-* / linux-* / mac-* keys) so we don't reuse the Windows-targeted
# files in distribution/jpackage/.
SWING_PROPS=$GENERATED/JSignPdf-swing.properties
{
    echo "# Generated by build-macos-installers.sh — do not edit by hand."
    swing_opts="-Djsignpdf.swing=true ${COMMON_JVM_OPTIONS[*]}"
    echo "java-options=$swing_opts"
} > "$SWING_PROPS"

# JSignPdfC is the CLI variant. On macOS the launcher binary lands in
# Contents/MacOS/ and runs in whatever terminal the user launches it from;
# no console-attaching flag is needed. Inheriting java-options (by leaving
# the key unset) gives it the same JVM args as the main launcher.
JSIGNPDFC_PROPS=$GENERATED/JSignPdfC.properties
{
    echo "# Generated by build-macos-installers.sh — do not edit by hand."
    echo "# Inherits java-options, main-jar, and main-class from the main launcher."
} > "$JSIGNPDFC_PROPS"

INSTALLCERT_PROPS=$GENERATED/InstallCert.properties
{
    echo "# Generated by build-macos-installers.sh — do not edit by hand."
    echo "main-jar=InstallCert.jar"
    echo "main-class=net.sf.jsignpdf.InstallCert"
} > "$INSTALLCERT_PROPS"

# Modules to bundle in the runtime image. --add-modules replaces (not extends)
# jpackage's auto-detected set, so we enumerate everything explicitly:
#   * java.se          — aggregator that pulls in java.desktop, java.naming,
#                        java.sql, java.xml, etc. — what jdeps would normally
#                        derive but can't here because the JavaFX classifier
#                        jars reference classes not on the classpath.
#   * jdk.crypto.cryptoki — PKCS#11; reached only via --add-exports, so jdeps
#                           never sees the dependency.
#   * jdk.crypto.ec    — elliptic-curve algorithms used by some signers.
#   * jdk.security.auth — JAAS callbacks used by PKCS#11 login flows.
#   * jdk.unsupported  — sun.misc.Unsafe, used transitively by JavaFX/marlin.
#   * jdk.localedata   — non-en locales for the UI.
RUNTIME_MODULES=java.se,jdk.crypto.cryptoki,jdk.crypto.ec,jdk.security.auth,jdk.unsupported,jdk.localedata

# 1. Build the app-image (one runtime, four launchers).
echo "==> jpackage --type app-image"
jpackage \
    --type app-image \
    --input "$STAGING" \
    --main-jar JSignPdf.jar \
    --main-class net.sf.jsignpdf.Signer \
    --name JSignPdf \
    --app-version "$APP_VERSION" \
    --vendor 'Josef Cacek' \
    --copyright 'Josef Cacek' \
    --description 'JSignPdf adds digital signatures to PDF documents' \
    --icon "$ICON_ICNS" \
    --dest "$OUT" \
    --add-modules "$RUNTIME_MODULES" \
    "${MAIN_JVM_ARGS[@]}" \
    --add-launcher "JSignPdf-swing=$SWING_PROPS" \
    --add-launcher "JSignPdfC=$JSIGNPDFC_PROPS" \
    --add-launcher "InstallCert=$INSTALLCERT_PROPS"

APP=$OUT/JSignPdf.app
[[ -d "$APP" ]] || die "expected $APP not found"

# 2. Build the DMG from the app-image.
echo "==> jpackage --type dmg"
jpackage \
    --type dmg \
    --app-image "$APP" \
    --name JSignPdf \
    --app-version "$APP_VERSION" \
    --vendor 'Josef Cacek' \
    --copyright 'Josef Cacek' \
    --description 'JSignPdf adds digital signatures to PDF documents' \
    --license-file "$ROOT/distribution/licenses/MPL-2.0.txt" \
    --about-url 'https://jsignpdf.eu/' \
    --icon "$ICON_ICNS" \
    --dest "$OUT"

mv "$OUT/JSignPdf-$APP_VERSION.dmg" "$UPLOAD/JSignPdf-$VERSION-mac-aarch64.dmg"

echo
echo "Done. Artifacts:"
ls -lh "$UPLOAD"/JSignPdf-*-mac-aarch64.dmg
