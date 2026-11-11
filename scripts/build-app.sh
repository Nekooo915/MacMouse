#!/bin/bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

build_args=(
    --configuration release
    --manifest-cache local
    --cache-path "$root/.build/cache"
    --config-path "$root/.build/config"
    --security-path "$root/.build/security"
)
universal=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --universal) universal=true ;;
        --disable-sandbox) build_args+=(--disable-sandbox) ;;
        *) printf 'Usage: %s [--universal] [--disable-sandbox]\n' "$0" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p .build dist
export CLANG_MODULE_CACHE_PATH="$root/.build/module-cache"
work="$(mktemp -d "$root/dist/.MacMouse.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
app="$work/MacMouse.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

if [[ "$universal" == true ]]; then
    for arch in arm64 x86_64; do
        triple="$arch-apple-macosx"
        swift build "${build_args[@]}" --triple "$triple"
        bin_dir="$(swift build "${build_args[@]}" --triple "$triple" --show-bin-path)"
        cp "$bin_dir/MacMouse" "$work/MacMouse-$arch"
    done
    lipo -create "$work/MacMouse-arm64" "$work/MacMouse-x86_64" -output "$app/Contents/MacOS/MacMouse"
else
    swift build "${build_args[@]}"
    bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
    cp "$bin_dir/MacMouse" "$app/Contents/MacOS/MacMouse"
fi

cp scripts/Info.plist "$app/Contents/Info.plist"
swift scripts/make-app-icon.swift "$app/Contents/Resources/MacMouse.icns"
codesign --force --sign - "$app"
codesign --verify --strict "$app"

destination="$root/dist/MacMouse.app"
if [[ -e "$destination" ]]; then
    mv "$destination" "$work/previous.app"
fi
if ! mv "$app" "$destination"; then
    if [[ -e "$work/previous.app" ]]; then
        mv "$work/previous.app" "$destination"
    fi
    exit 1
fi
printf 'Built %s\n' "$destination"
