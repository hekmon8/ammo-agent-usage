#!/bin/sh
# Usage: configure-apns.sh KEY.p8 TOPIC CONFIG ENDPOINT [--dry-run]
set -eu
exec python3 "$(dirname "$0")/configure_apns.py" "$@"
