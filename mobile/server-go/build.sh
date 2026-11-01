#!/bin/sh
# Builds the Go server.   sh mobile/server-go/build.sh test   -> build/ytdl-server-linux (for the tests)
#                         sh mobile/server-go/build.sh mac    -> build/ytdl-server-darwin-{arm64,amd64}
set -e
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SELF")"
rm -rf web && mkdir web && cp -r ../server/web/* web/      # the web app is embedded in the binary
mkdir -p build
case "${1:-test}" in
  test) go build -trimpath -ldflags "-s -w" -o build/ytdl-server-linux . ;;
  mac)  for a in arm64 amd64; do CGO_ENABLED=0 GOOS=darwin GOARCH=$a go build -trimpath -ldflags "-s -w" -o build/ytdl-server-darwin-$a .; done ;;
  all)  sh "$SELF" test; sh "$SELF" mac ;;
esac
ls -la build
