#!/usr/bin/env bash
# The actual dev loop, run INSIDE reactivecircus/android-emulator-runner:
# the emulator is already booted and `adb` is on PATH. cwd is the repo root.
#
#   start Metro (App's way) -> install APK -> launch app ->
#   wait for the SignIn screen -> screenshot -> edit one visible source
#   string -> wait for Fast Refresh to render it -> screenshot.
#
# Readiness/propagation are detected by polling the on-device UI hierarchy
# (uiautomator), not by fixed sleeps: the cold first render is slow and
# variable, so we wait for the actual screen text instead of guessing.
#
# APK_PATH is exported by the "Download prebuilt APK" workflow step.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/App"
ART="$ROOT/artifacts"
PKG="com.expensify.chat.dev"          # developmentDebug applicationId
ACTIVITY="com.expensify.chat.MainActivity"
METRO_READY_TIMEOUT=180               # wait for the packager
SIGNIN_TIMEOUT=240                    # wait for the first screen (cold render)
FR_TIMEOUT=40                         # first try Fast Refresh (App's chosen mechanism)
RELOAD_TIMEOUT=200                    # fallback: explicit reload re-pulls the bundle
ORIG_LABEL="Phone or email"
EDIT_TOKEN="CI-EDIT"                  # prefix added by edit-signin-label.sh

mkdir -p "$ART"

# Kill Metro on exit. A lingering `rock start` (node) process outliving the
# script is what hangs reactivecircus's emulator teardown until the job timeout,
# so we always stop it - even on failure.
cleanup() {
  echo "==> cleanup: stopping Metro"
  pkill -f "react-native start" 2>/dev/null || true
  pkill -f "rock start"         2>/dev/null || true
  pkill -f "metro"              2>/dev/null || true
}
trap cleanup EXIT

# Best-effort dump of the current on-device UI hierarchy as XML.
dump_ui() {
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 || true
  adb exec-out cat /sdcard/ui.xml 2>/dev/null || true
}

# Poll the UI for a literal string. $1=needle $2=timeout_s. 0=found, 1=timeout.
wait_for_ui() {
  local needle="$1" timeout="$2" deadline=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if dump_ui | grep -qF "$needle"; then return 0; fi
    sleep 5
  done
  return 1
}

# 1. Start Metro the App's way: `npm start` == `npx rock start`. Backgrounded;
#    logs to an artifact. We deliberately do NOT use the melvin PR's
#    `react-native start --config <wrapper>` (that only silenced LogBox); here we
#    want App's vanilla bundler.
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

# 6. Wait for the SignIn screen (poll for the "Continue" button text), then
#    screenshot BEFORE - it must show the ORIGINAL "Phone or email" label.
echo "==> Waiting for the SignIn screen (up to ${SIGNIN_TIMEOUT}s)"
if wait_for_ui "Continue" "$SIGNIN_TIMEOUT"; then
  echo "==> SignIn screen is up"
else
  echo "::warning::SignIn screen not detected via uiautomator in ${SIGNIN_TIMEOUT}s; capturing anyway"
fi
sleep 3
adb exec-out screencap -p > "$ART/01-before.png"
echo "==> Captured $ART/01-before.png"

# 7. THE DEV-LOOP EDIT: change one visible source string on the first screen.
"$ROOT/scripts/edit-signin-label.sh" "$APP"

# 8. Propagate the edit to the running app.
#    First try Fast Refresh (the chosen mechanism). App's translation edits do
#    NOT reliably hot-swap via Fast Refresh (the en.ts module is not a component
#    boundary, and no HMR delta is emitted), so if the label has not rendered in
#    a short window we force an explicit reload: force-stop + relaunch makes the
#    app re-pull the bundle from Metro with the edit baked in - the same effect
#    as the melvin PR's `agent-device metro reload`.
echo "==> Trying Fast Refresh first (polling UI for '$EDIT_TOKEN', up to ${FR_TIMEOUT}s)"
if wait_for_ui "$EDIT_TOKEN" "$FR_TIMEOUT"; then
  PROPAGATED=1; HOW="Fast Refresh"
else
  echo "==> Fast Refresh did not render the edit; forcing an explicit reload (re-pull bundle)"
  adb shell am force-stop "$PKG"
  sleep 2
  adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 \
    || adb shell am start -n "$PKG/$ACTIVITY"
  echo "==> Waiting for the reloaded screen to render the edit (up to ${RELOAD_TIMEOUT}s)"
  if wait_for_ui "$EDIT_TOKEN" "$RELOAD_TIMEOUT"; then
    PROPAGATED=1; HOW="explicit reload (force-stop + relaunch)"
  else
    PROPAGATED=0; HOW="none"
  fi
fi
sleep 2
adb exec-out screencap -p > "$ART/02-after.png"
echo "==> Captured $ART/02-after.png"

# 9. Verify: the edited string must be rendered on the device.
echo "==> Verifying the edit propagated"
if [ "${PROPAGATED:-0}" = "1" ]; then
  echo "SUCCESS: '${EDIT_TOKEN} ${ORIG_LABEL}' is rendered on the device via ${HOW} - the JS edit propagated to the running app."
else
  echo "::error::The edit did NOT render (tried Fast Refresh ${FR_TIMEOUT}s + explicit reload ${RELOAD_TIMEOUT}s). Inspect $ART/02-after.png and $ART/metro.log."
  exit 1
fi
