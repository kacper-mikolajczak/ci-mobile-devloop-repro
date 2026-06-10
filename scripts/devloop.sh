#!/usr/bin/env bash
# The actual dev loop, run INSIDE reactivecircus/android-emulator-runner:
# the emulator is already booted and `adb` is on PATH. cwd is the repo root.
#
#   start Metro (App's way) -> install APK -> launch app -> screenshot ->
#   edit one visible source string -> wait for Fast Refresh -> screenshot.
#
# APK_PATH is exported by the "Download prebuilt APK" workflow step.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/App"
ART="$ROOT/artifacts"
PKG="com.expensify.chat.dev"          # developmentDebug applicationId
ACTIVITY="com.expensify.chat.MainActivity"
METRO_READY_TIMEOUT=180               # seconds to wait for the packager
FAST_REFRESH_WAIT=45                  # seconds to let the edit propagate

mkdir -p "$ART"

# 1. Start Metro the App's way: `npm start` == `npx rock start`. Backgrounded;
#    logs go to an artifact so a failure is debuggable. We deliberately do NOT
#    use the melvin PR's `react-native start --config <wrapper>` - that only
#    existed to silence LogBox; here we want App's vanilla bundler.
echo "==> Starting Metro (App's way: npx rock start)"
( cd "$APP" && nohup npx rock start > "$ART/metro.log" 2>&1 & )

# 2. Wait for the packager to report ready.
echo "==> Waiting for Metro (packager-status:running, timeout ${METRO_READY_TIMEOUT}s)"
deadline=$((SECONDS + METRO_READY_TIMEOUT))
until curl -sf -m 3 http://127.0.0.1:8081/status 2>/dev/null | grep -q "packager-status:running"; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "::error::Metro did not become ready in ${METRO_READY_TIMEOUT}s"
    tail -n 120 "$ART/metro.log" 2>/dev/null || true
    exit 1
  fi
  sleep 3
done
echo "==> Metro is up"

# 3. Bridge Metro's port into the emulator, then install the prebuilt APK.
adb reverse tcp:8081 tcp:8081
echo "==> Installing APK: $APK_PATH"
adb install -r -d -t "$APK_PATH"

# 4. Pre-warm the Android JS bundle (cold compile is slow) so the app loads past
#    the splash quickly instead of timing out on first launch.
echo "==> Pre-warming the Android JS bundle (this can take a few minutes)"
curl -sS --max-time 900 \
  "http://localhost:8081/index.bundle?platform=android&dev=true&minify=false" \
  -o /dev/null || echo "::warning::bundle pre-warm did not finish; app may sit on splash longer"

# 5. Launch the app.
echo "==> Launching $PKG"
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 \
  || adb shell am start -n "$PKG/$ACTIVITY"

# 6. Let the first (logged-out SignIn) screen render, then screenshot BEFORE.
echo "==> Waiting for the first screen to render"
sleep 45
adb exec-out screencap -p > "$ART/01-before.png"
echo "==> Captured $ART/01-before.png"

# 7. THE DEV-LOOP EDIT: change one visible source string on the first screen.
"$ROOT/scripts/edit-signin-label.sh" "$APP"

# 8. Wait for Fast Refresh to push the edit to the running app (spec point 4).
echo "==> Waiting ${FAST_REFRESH_WAIT}s for Fast Refresh to propagate the edit"
sleep "$FAST_REFRESH_WAIT"
adb exec-out screencap -p > "$ART/02-after.png"
echo "==> Captured $ART/02-after.png"

# 9. Simplest possible verification: the screenshots must differ. The real proof
#    is eyeballing the uploaded before/after PNGs.
echo "==> Verifying the edit propagated"
if cmp -s "$ART/01-before.png" "$ART/02-after.png"; then
  echo "::warning::before/after screenshots are IDENTICAL - Fast Refresh may not have propagated."
  echo "::warning::Inspect $ART/metro.log and the uploaded screenshots."
else
  echo "SUCCESS: screenshots differ - the source edit propagated to the running app via Fast Refresh."
fi
