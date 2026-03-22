#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="QuickEye"
DEFAULT_DEST="${HOME}/Applications"
DEST_DIR="${DEFAULT_DEST}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --system)
      DEST_DIR="/Applications"
      shift
      ;;
    --dest)
      DEST_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--system] [--dest <path>]" >&2
      exit 1
      ;;
  esac
done

"${ROOT_DIR}/scripts/build-app.sh"

mkdir -p "${DEST_DIR}"
rm -rf "${DEST_DIR}/Quick Eye.app"
ditto "${ROOT_DIR}/dist/${APP_NAME}.app" "${DEST_DIR}/${APP_NAME}.app"
touch "${DEST_DIR}/${APP_NAME}.app"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "${LSREGISTER}" ]]; then
  "${LSREGISTER}" -f "${DEST_DIR}/${APP_NAME}.app" >/dev/null 2>&1 || true
fi

if command -v mdimport >/dev/null 2>&1; then
  mdimport "${DEST_DIR}/${APP_NAME}.app" >/dev/null 2>&1 || true
fi

echo "Installed ${APP_NAME}.app to ${DEST_DIR}"
