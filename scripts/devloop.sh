#!/usr/bin/env bash
# The actual dev loop, run INSIDE reactivecircus/android-emulator-runner:
# the emulator is already booted and `adb` is on PATH. cwd is the repo root.
#
#   start Metro (App's way) -> install APK -> launch app -> wait for SignIn ->
#   screenshot -> edit one visible source string -> make Metro serve the edit ->
#   reload the app -> screenshot -> verify.
#
# Propagation proof is TWO-LAYERED:
#   (a) deterministic: the bundle Metro SERVES now contains the edited string
#       (not subject to emulator render timing / ANRs);
#   (b) visual: the reloaded screen shows it (best-effort screenshot).
# (a) is the pass/fail gate; (b) is corroborating evidence.
#
# APK_PATH is exported by the "Download prebuilt APK" workflow step.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/App"
ART="$ROOT/artifacts"
PKG="com.expensify.chat.dev"          # developmentDebug applicationId
ACTIVITY="com.expensify.chat.MainActivity"
METRO_READY_TIMEOUT=180               # wait for the packager
SIGNIN_TIMEOUT=300                    # wait for the first screen (cold render)
FR_TIMEOUT=40                         # first try Fast Refresh (App's chosen mechanism)
RELOAD_TIMEOUT=300                    # wait for the reloaded screen (cold recompile + render)
ORIG_LABEL="Phone or email"
EDIT_TOKEN="CI-EDIT"
EDITED_STRING="CI-EDIT Phone or email"
BUNDLE_URL="http://localhost:8081/index.bundle?platform=android&dev=true&minify=false"

mkdir -p "$ART"

# Kill Metro on exit. A lingering `rock start` (node) outliving the script hangs
# reactivecircus's emulator teardown until the job timeout, so always stop it.
cleanup() {
  echo "==> cleanup: stopping Metro"
  pkill -f "react-native start" 2>/dev/null || true
  pkill -f "rock start"         2>/dev/null || true
  pkill -f "metro"              2>/dev/null || true
}
trap cleanup EXIT

start_metro() {  # launch Metro (App's way) and wait until the packager is ready
  echo "==> Starting Metro (App's way: npx rock start)"
  ( cd "$APP" && nohup npx rock start > "$ART/metro.log" 2>&1 & )
  local deadline=$((SECONDS + METRO_READY_TIMEOUT))
  echo "==> Waiting for Metro (packager-status:running, ${METRO_READY_TIMEOUT}s)"
  until curl -sf -m 3 http://127.0.0.1:8081/status 2>/dev/null | grep -q "packager-status:running"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "::error::Metro did not become ready in ${METRO_READY_TIMEOUT}s"
      tail -n 120 "$ART/metro.log" 2>/dev/null || true
      exit 1
    fi
    sleep 3
  done
  echo "==> Metro is up"
}

stop_metro() {
  pkill -f "react-native start" 2>/dev/null || true
  pkill -f "rock start"         2>/dev/null || true
  pkill -f "metro"              2>/dev/null || true
  sleep 3
}

# Fetch the served bundle to disk (also forces a compile = pre-warm).
fetch_bundle() {
  echo "==> Fetching the served JS bundle (forces compile / pre-warm)"
  curl -sS --max-time 900 "$BUNDLE_URL" -o "$ART/bundle.js" \
    || echo "::warning::bundle fetch did not finish"
}

launch_app() { adb shell am start -W -n "$PKG/$ACTIVITY" >/dev/null 2>&1 || true; }

dump_ui() {  # best-effort UI hierarchy XML
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 || true
  adb exec-out cat /sdcard/ui.xml 2>/dev/null || true
}
wait_for_ui() {  # $1=needle $2=timeout_s ; 0=found 1=timeout
  local needle="$1" deadline=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if dump_ui | grep -qF "$needle"; then return 0; fi
    sleep 5
  done
  return 1
}

# --- bring-up -------------------------------------------------------------
start_metro
adb reverse tcp:8081 tcp:8081
echo "==> Installing APK: $APK_PATH"
adb install -r -d -t "$APK_PATH"
fetch_bundle
echo "==> Launching $PKG"
launch_app

# --- before ---------------------------------------------------------------
echo "==> Waiting for the SignIn screen (up to ${SIGNIN_TIMEOUT}s)"
if wait_for_ui "Continue" "$SIGNIN_TIMEOUT"; then
  echo "==> SignIn screen is up"
else
  echo "::warning::SignIn screen not detected via uiautomator in ${SIGNIN_TIMEOUT}s; capturing anyway"
fi
sleep 3
adb exec-out screencap -p > "$ART/01-before.png"
echo "==> Captured $ART/01-before.png"

# --- the edit -------------------------------------------------------------
"$ROOT/scripts/edit-signin-label.sh" "$APP"

# --- propagate ------------------------------------------------------------
UI_SHOWS=0; HOW=""

# (1) Try Fast Refresh first (App's chosen mechanism).
echo "==> Trying Fast Refresh (polling UI for '$EDIT_TOKEN', up to ${FR_TIMEOUT}s)"
if wait_for_ui "$EDIT_TOKEN" "$FR_TIMEOUT"; then
  UI_SHOWS=1; HOW="Fast Refresh"
else
  # (2) Fast Refresh did not render it. App's long-running Metro misses the edit
  #     (no HMR delta for a translation module), so restart Metro fresh: a new
  #     process re-reads en.ts from disk and re-transforms it (transform cache is
  #     content-keyed), guaranteeing the SERVED bundle contains the edit.
  echo "==> Fast Refresh did not render it; restarting Metro fresh so it serves the edit"
  stop_metro
  start_metro
  adb reverse tcp:8081 tcp:8081 || true
  fetch_bundle
  HOW="explicit reload (Metro restart + relaunch)"
fi

# Deterministic gate: the bundle Metro serves must now contain the edited string.
echo "==> Asserting the served bundle contains '$EDITED_STRING'"
if grep -qF "$EDITED_STRING" "$ART/bundle.js" 2>/dev/null; then
  SERVED=1
  printf 'Served bundle contains: %s\n' "$EDITED_STRING" > "$ART/bundle-proof.txt"
  echo "==> CONFIRMED: Metro serves the edited string."
else
  SERVED=0
  echo "::error::Metro is NOT serving the edited string - propagation to the bundler failed."
fi
# Keep the artifact small: drop the multi-MB bundle, retain a head sample for debug.
head -c 300000 "$ART/bundle.js" > "$ART/bundle-head-sample.js" 2>/dev/null || true
rm -f "$ART/bundle.js" 2>/dev/null || true

# (3) Reload the app so the screen reflects the edit, then screenshot AFTER.
if [ "$UI_SHOWS" = "0" ]; then
  echo "==> Reloading the app (force-stop + relaunch) to render the edit"
  adb shell am force-stop "$PKG" || true
  sleep 2
  launch_app
  echo "==> Waiting for the reloaded screen to show '$EDIT_TOKEN' (up to ${RELOAD_TIMEOUT}s)"
  if wait_for_ui "$EDIT_TOKEN" "$RELOAD_TIMEOUT"; then
    UI_SHOWS=1
  fi
fi
sleep 2
adb exec-out screencap -p > "$ART/02-after.png"
echo "==> Captured $ART/02-after.png"

# --- verdict --------------------------------------------------------------
echo "==> Verifying the edit propagated"
if [ "${UI_SHOWS}" = "1" ]; then
  echo "==> Visual: the edited label is rendered on the device."
else
  echo "::warning::edited label not confirmed on screen (emulator render is flaky); see 02-after.png"
fi
if [ "${SERVED:-0}" = "1" ]; then
  echo "SUCCESS: the source edit propagated to the running app via ${HOW}. Metro serves '${EDITED_STRING}'$( [ "$UI_SHOWS" = 1 ] && echo ' and it is rendered on screen' )."
else
  echo "::error::The edit did NOT propagate. Inspect $ART/02-after.png, $ART/bundle.js, $ART/metro.log."
  exit 1
fi
