#!/bin/sh

set -eu

export PATH="/Users/haimbender/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

PROD_BUNDLE_ID="com.neonnode.chat94app"

if [ "${PLATFORM_NAME:-}" != "iphoneos" ]; then
  echo "info: skipping Sentry dSYM upload for non-device platform '${PLATFORM_NAME:-unknown}'"
  exit 0
fi

if [ "${CONFIGURATION:-}" != "Release" ]; then
  echo "info: skipping Sentry dSYM upload for non-Release build '${CONFIGURATION:-unknown}'"
  exit 0
fi

if [ "${PRODUCT_BUNDLE_IDENTIFIER:-}" != "$PROD_BUNDLE_ID" ]; then
  echo "info: skipping Sentry dSYM upload for non-production app '${PRODUCT_BUNDLE_IDENTIFIER:-unknown}'"
  exit 0
fi

if [ -z "${DWARF_DSYM_FOLDER_PATH:-}" ] || [ -z "${DWARF_DSYM_FILE_NAME:-}" ]; then
  echo "info: skipping Sentry dSYM upload because dSYM environment is unavailable"
  exit 0
fi

DSYM_PATH="${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}"
if [ ! -d "$DSYM_PATH" ]; then
  echo "info: skipping Sentry dSYM upload because '$DSYM_PATH' was not found"
  exit 0
fi

if ! command -v sentry >/dev/null 2>&1; then
  echo "warning: sentry CLI not found; skipping dSYM upload"
  exit 0
fi

AUTH_TOKEN="$(sentry auth token 2>/dev/null || true)"
if [ -z "$AUTH_TOKEN" ]; then
  echo "warning: no Sentry auth token available; skipping dSYM upload"
  exit 0
fi

TMP_ZIP="$(mktemp -t chat4000-dsym).zip"
cleanup() {
  rm -f "$TMP_ZIP"
}
trap cleanup EXIT

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$DSYM_PATH" "$TMP_ZIP"

echo "info: uploading production Release dSYM '$DWARF_DSYM_FILE_NAME' to Sentry"
/usr/bin/curl --fail --silent --show-error \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -F "file=@${TMP_ZIP}" \
  "https://us.sentry.io/api/0/projects/char94/chat4000app-ios/files/dsyms/"

echo "info: Sentry dSYM upload finished"
