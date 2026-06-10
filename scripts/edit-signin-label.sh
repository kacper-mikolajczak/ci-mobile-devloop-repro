#!/usr/bin/env bash
# The single source edit for the dev loop: change the "Phone or email" input
# label that is visible on the first (logged-out) SignIn screen.
#
# Source: App/src/languages/en.ts -> loginForm.phoneOrEmail.
# Rendered by App/src/pages/signin/LoginForm/BaseLoginForm.tsx as the input
# label, so it shows on the first screen WITHOUT signing in.
set -euo pipefail

APP="${1:-App}"
EN="$APP/src/languages/en.ts"

if ! grep -q "phoneOrEmail: 'Phone or email'," "$EN"; then
  echo "::error::Expected string \"phoneOrEmail: 'Phone or email',\" not found in $EN."
  echo "::error::App's en.ts changed; update this script's target."
  exit 1
fi

echo "==> Editing $EN: phoneOrEmail label"
sed -i "s/phoneOrEmail: 'Phone or email',/phoneOrEmail: 'CI-EDIT Phone or email',/" "$EN"
grep -n "phoneOrEmail:" "$EN" | head -1
