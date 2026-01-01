#!/usr/bin/env bash
set -euo pipefail

if command -v /usr/libexec/java_home >/dev/null 2>&1; then
  JDK_17=$(/usr/libexec/java_home -v 17 2>/dev/null || true)
  if [ -n "${JDK_17}" ]; then
    export JAVA_HOME="${JDK_17}"
  fi
fi

if [ -z "${JAVA_HOME:-}" ]; then
  echo "JAVA_HOME is not set and JDK 17 was not found."
  echo "Install JDK 17 or export JAVA_HOME before running Flutter."
  exit 1
fi

exec flutter "$@"
