#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
work_root="$project_root/work"
scratch_path="$work_root/ScreenFence-build"
app_path="$project_root/dist/屏界.app"

if pgrep -x ScreenFence >/dev/null; then
    printf '请先退出正在运行的屏界，再构建更新，避免覆盖正在执行的 App。\n' >&2
    exit 1
fi

mkdir -p "$work_root" "$scratch_path" "$project_root/dist"
python3 "$script_dir/sign-app.py" --setup
swift build --package-path "$project_root" --scratch-path "$scratch_path" \
    --configuration release --product ScreenFence
binary_dir="$(swift build --package-path "$project_root" --scratch-path "$scratch_path" \
    --configuration release --show-bin-path)"

package_work="$(mktemp -d "$work_root/ScreenFence-package.XXXXXX")"
trap 'rm -rf "$package_work"' EXIT
staged_app="$package_work/屏界.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
install -m 755 "$binary_dir/ScreenFence" "$staged_app/Contents/MacOS/ScreenFence"

cat > "$staged_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>屏界</string>
    <key>CFBundleName</key><string>屏界</string>
    <key>CFBundleExecutable</key><string>ScreenFence</string>
    <key>CFBundleIdentifier</key><string>com.miaopasi.screenfence</string>
    <key>CFBundleVersion</key><string>6</string>
    <key>CFBundleShortVersionString</key><string>1.2.3</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>ScreenFence</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

swift "$script_dir/make-icon.swift" "$package_work/ScreenFence.iconset"
iconutil --convert icns --output "$staged_app/Contents/Resources/ScreenFence.icns" \
    "$package_work/ScreenFence.iconset"
sed -E '/^```/d; s/^#{1,6} //; s/\*\*//g; s/`//g' \
    "$project_root/README.md" > "$staged_app/Contents/Resources/使用说明.txt"
plutil -lint "$staged_app/Contents/Info.plist"
python3 "$script_dir/sign-app.py" "$staged_app"

ditto "$staged_app" "$app_path"
python3 "$script_dir/sign-app.py" --verify "$app_path"
printf 'App 已生成：%s\n' "$app_path"
