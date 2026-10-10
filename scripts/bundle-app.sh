#!/bin/zsh
# Build AppMixer.app bundle from SwiftPM executable (no full Xcode required).
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP="dist/AppMixer.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AppMixer "$APP/Contents/MacOS/AppMixer"
cp Info.plist "$APP/Contents/Info.plist"
cat > "$APP/Contents/Resources/run.sh" <<'SH'
#!/bin/zsh
exec "$(dirname "$0")/../MacOS/AppMixer"
SH
chmod +x "$APP/Contents/Resources/run.sh"
echo "Built $APP"
echo "Run: open $APP"
echo "First launch: allow Screen & System Audio Recording when prompted."
