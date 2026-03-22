#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
APP_NAME="QuickEye"
EXECUTABLE_NAME="quick-eye"
APP_BUNDLE_PATH="${ROOT_DIR}/dist/${APP_NAME}.app"
EXECUTABLE_SOURCE="${ROOT_DIR}/.build/${BUILD_CONFIG}/${EXECUTABLE_NAME}"
INFO_PLIST_SOURCE="${ROOT_DIR}/App/Info.plist"

cd "${ROOT_DIR}"

swift build -c "${BUILD_CONFIG}"

if [[ ! -x "${EXECUTABLE_SOURCE}" ]]; then
  echo "Expected executable at ${EXECUTABLE_SOURCE}, but it was not found." >&2
  exit 1
fi

rm -rf "${APP_BUNDLE_PATH}"
mkdir -p "${APP_BUNDLE_PATH}/Contents/MacOS"
mkdir -p "${APP_BUNDLE_PATH}/Contents/Resources"

cp "${INFO_PLIST_SOURCE}" "${APP_BUNDLE_PATH}/Contents/Info.plist"
cp "${EXECUTABLE_SOURCE}" "${APP_BUNDLE_PATH}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE_PATH}/Contents/MacOS/${APP_NAME}"
printf 'APPL????' > "${APP_BUNDLE_PATH}/Contents/PkgInfo"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BUNDLE_VERSION="$(git rev-parse --short HEAD)"
else
  BUNDLE_VERSION="1"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUNDLE_VERSION}" "${APP_BUNDLE_PATH}/Contents/Info.plist" >/dev/null

echo "Built ${APP_BUNDLE_PATH}"
