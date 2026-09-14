#!/usr/bin/env bash
#
# Assembles the flashable Integrity-Box module zip.
#
# The shell/webroot part of the module lives in this tree, but classes.dex and
# zygisk/*.so are built from the two PlayIntegrityFork branches that upstream
# also uses (see zygisk/source.md and legacy/source.md):
#
#   integrity-box branch -> classes.dex + zygisk/{arm64-v8a,armeabi-v7a}.so
#   legacy branch        -> legacy/legacy.dex + legacy/zygisk/*.so (x86 fallback)
#
# Build those first (CI does this automatically), then point this script at the
# populated module/ directories it produces:
#
#   cd PlayIntegrityFork && ./gradlew :app:assembleRelease
#   ./build.sh --pifork-artifacts PlayIntegrityFork/module \
#              --legacy-artifacts /path/to/legacy/checkout/module
#
# Without --legacy-artifacts the zip is still produced, just without the x86
# fallback (fine for arm-only devices, not for a release).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PIF=""
LEG=""
OUT=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--pifork-artifacts)
		PIF="${2:?missing value}"
		shift 2
		;;
	--legacy-artifacts)
		LEG="${2:?missing value}"
		shift 2
		;;
	--out)
		OUT="${2:?missing value}"
		shift 2
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 2
		;;
	esac
done

if [[ -z "$PIF" ]]; then
	echo "usage: $0 --pifork-artifacts <module dir> [--legacy-artifacts <module dir>] [--out <zip>]" >&2
	exit 2
fi

require_artifacts() {
	local dir="$1" what="$2"
	[[ -f "$dir/classes.dex" ]] || {
		echo "$what: missing $dir/classes.dex" >&2
		exit 1
	}
	local found=0
	for so in "$dir"/zygisk/*.so; do
		[[ -e "$so" ]] && found=1
	done
	[[ "$found" == 1 ]] || {
		echo "$what: missing $dir/zygisk/*.so" >&2
		exit 1
	}
}
require_artifacts "$PIF" "modern artifacts"
if [[ -n "$LEG" ]]; then
	require_artifacts "$LEG" "legacy artifacts"
fi

VERSION="$(sed -n 's/^version=//p' "$ROOT/module.prop" | head -1)"
[[ -n "$VERSION" ]] || {
	echo "cannot read version from module.prop" >&2
	exit 1
}
if [[ -z "$OUT" ]]; then
	OUT="$ROOT/build/Integrity-Box-${VERSION}-$(date +%d-%m-%Y).zip"
elif [[ "$OUT" != /* ]]; then
	OUT="$ROOT/$OUT"
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/integrity-box-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

copy_tree_file() {
	local rel="$1"
	mkdir -p "$STAGE/$(dirname "$rel")"
	cp -a "$ROOT/$rel" "$STAGE/$rel"
}

# Runtime files of the module (what upstream ships in the release zip).
for f in META-INF action.sh common_func.sh common_setup.sh customize.sh \
	module.prop post-fs-data.sh service.sh system.prop uninstall.sh verify.sh \
	box.png key.png; do
	copy_tree_file "$f"
done
copy_tree_file toolkit/legacy.prop
copy_tree_file toolkit/pixelify.prop

# webroot as-is, except the TRANSLATIONS submodule: its repository layout
# (languages/, addon/, credits/, WebUI/, sample/) is flattened into the handful
# of files the WebUI loads at runtime.
while IFS= read -r rel; do
	copy_tree_file "webroot/$rel"
done < <(cd "$ROOT/webroot" && find . -type f ! -path './TRANSLATIONS/*' | sed 's|^\./||')

TR="$STAGE/webroot/TRANSLATIONS"
mkdir -p "$TR"
cp -a "$ROOT/webroot/TRANSLATIONS/languages/"*.js "$TR/"
cp -a "$ROOT/webroot/TRANSLATIONS/addon/meow.js" "$TR/"
cp -a "$ROOT/webroot/TRANSLATIONS/credits/contributors.json" "$TR/"

# Release-time files that upstream generates while packaging.
: >"$STAGE/apps.txt"
cp -a "$ROOT/changelog.md" "$STAGE/CHANGELOG.md"
cat >"$STAGE/credits.md" <<'EOF'
## Credits
- ☝️GOD, for everything ♥️

- @ez-me for https://github.com/ez-me/ezme-nodebug

- @osm0sis for https://github.com/osm0sis/PlayIntegrityFork

- Everyone who supported me

- You, for using this module 
EOF
cp -a "$ROOT/PlayIntegrityFork/module/migrate.sh" "$STAGE/migrate.sh"
cp -a "$ROOT/PlayIntegrityFork/module/osm0sis.sh" "$STAGE/osm0sis.sh"

# Modern artifacts (Shadow Hook path, arm32/arm64).
mkdir -p "$STAGE/zygisk"
cp -a "$PIF/classes.dex" "$STAGE/classes.dex"
for so in "$PIF"/zygisk/*.so; do
	cp -a "$so" "$STAGE/zygisk/$(basename "$so")"
done
printf '%s' 'https://github.com/MeowDump/PlayIntegrityFork/tree/integrity-box' >"$STAGE/zygisk/source.md"

# Legacy artifacts (Dobby fallback for x86/x86_64 hardware).
if [[ -n "$LEG" ]]; then
	mkdir -p "$STAGE/legacy/zygisk"
	cp -a "$LEG/classes.dex" "$STAGE/legacy/legacy.dex"
	for so in "$LEG"/zygisk/*.so; do
		cp -a "$so" "$STAGE/legacy/zygisk/$(basename "$so")"
	done
	printf '%s' 'https://github.com/MeowDump/PlayIntegrityFork/tree/legacy' >"$STAGE/legacy/source.md"
	cat >"$STAGE/legacy/README.md" <<'EOF'
This `legacy` folder exists to keep the module compatible with older x86/x86_64 hardware, where Shadow Hook is not supported. Instead of maintaining separate modules for modern and legacy devices, both implementations are included in the same package and the correct one is selected automatically during installation.

On installation, IntegrityBox checks the device ABI:

- `armeabi-v7a` / `arm64-v8a` = Modern hardware >>> uses the latest Shadow Hook implementation. The `legacy` folder is removed because it is not needed.

- Other ABIs (mainly x86/x86_64) = Legacy hardware >>> the Shadow Hook files are replaced with the Dobby-based fallback from this folder.

The `v7a` and `v8a` variants are also kept in the legacy package as a safety measure. If ABI detection behaves unexpectedly, these files help prevent the module from failing due to missing architecture variant.

In short, this `legacy` folder allows one module to support both modern and legacy hardware without requiring separate releases, while modern devices continue to use the preferred Shadow Hook implementation

if you still have any questions feel free to contact me on telegram @TempMeow
EOF
else
	echo "warning: --legacy-artifacts not given, packaging without the x86 fallback" >&2
fi

# sha256 manifest used by verify.sh inside the installed module.
(
	cd "$STAGE"
	find . -type f ! -name hash | sed 's|^\./||' | LC_ALL=C sort |
		while IFS= read -r rel; do
			printf '%s|%s\n' "$rel" "$(sha256sum "$rel" | cut -d' ' -f1)"
		done >hash
)

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
(
	cd "$STAGE"
	zip -q -r -X "$OUT" .
)
echo "built: $OUT"
unzip -l "$OUT" | tail -2
