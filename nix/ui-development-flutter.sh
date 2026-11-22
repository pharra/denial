#!/bin/sh
# The Flutter entry point of the live development SDK. Its cache holds the
# compiler inputs and engine artifacts Flutter's own tool resolves, so no
# `--local-engine` is needed and nothing is downloaded.
set -eu
flutter_root='@flutterRoot@'
exec "$flutter_root/bin/cache/dart-sdk/bin/dartaotruntime" \
  "$flutter_root/bin/cache/flutter_tools.snapshot" \
  "$@"
