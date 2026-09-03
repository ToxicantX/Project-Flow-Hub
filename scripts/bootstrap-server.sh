#!/usr/bin/env bash
set -euo pipefail

public_key_file="${1:-}"
base="${FLOW_HUB_SITE_ROOT:-/var/www/draw.wsxcant.me}"
managed="$base/managed"

if [[ -z "$public_key_file" || ! -f "$public_key_file" ]]; then
  echo "Usage: bootstrap-server.sh <deploy-public-key>" >&2
  exit 2
fi

if ! id flowdeploy >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash flowdeploy
fi

install -d -o flowdeploy -g flowdeploy -m 700 /home/flowdeploy/.ssh
install -o flowdeploy -g flowdeploy -m 600 "$public_key_file" /home/flowdeploy/.ssh/authorized_keys
install -d -o flowdeploy -g flowdeploy -m 755 "$managed" "$managed/releases"

previous="$(readlink -f "$base/current")"
if [[ -z "$previous" || ! -f "$previous/index.html" ]]; then
  echo "Current release is invalid" >&2
  exit 2
fi

ln -sfn "$previous" "$managed/current"
chown -h flowdeploy:flowdeploy "$managed/current"
ln -sfn "$managed/current" "$base/current.next"
mv -Tf "$base/current.next" "$base/current"

if ! curl --fail --silent --show-error --insecure \
  --resolve draw.wsxcant.me:8443:127.0.0.1 \
  https://draw.wsxcant.me:8443/ >/dev/null; then
  ln -sfn "$previous" "$base/current.next"
  mv -Tf "$base/current.next" "$base/current"
  exit 1
fi

echo "Server bootstrap complete: $(readlink -f "$base/current")"
