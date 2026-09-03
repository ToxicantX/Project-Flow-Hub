#!/usr/bin/env bash
set -euo pipefail

release_id="${1:-}"
archive="${2:-}"
base="${FLOW_HUB_BASE:-/var/www/draw.wsxcant.me/managed}"

if [[ ! "$release_id" =~ ^[a-f0-9]{12}-[0-9]+-[0-9]+$ ]]; then
  echo "Invalid release id" >&2
  exit 2
fi

if [[ "$archive" != "/tmp/project-flow-hub-${release_id}.tar.gz" || ! -f "$archive" ]]; then
  echo "Release archive is missing" >&2
  exit 2
fi

release_dir="$base/releases/$release_id"
next_link="$base/current.next"
previous="$(readlink "$base/current" 2>/dev/null || true)"

if [[ -e "$release_dir" ]]; then
  echo "Release already exists" >&2
  exit 2
fi

cleanup_failed_release() {
  rm -f "$next_link" "$archive"
  rm -rf "$release_dir"
}
trap cleanup_failed_release ERR

mkdir -p "$release_dir"
tar -xzf "$archive" -C "$release_dir"
test -f "$release_dir/index.html"
test -f "$release_dir/health.json"

ln -sfn "$release_dir" "$next_link"
mv -Tf "$next_link" "$base/current"

if ! curl --fail --silent --show-error --insecure \
  --resolve draw.wsxcant.me:8443:127.0.0.1 \
  https://draw.wsxcant.me:8443/health.json >/dev/null; then
  if [[ -n "$previous" ]]; then
    ln -sfn "$previous" "$next_link"
    mv -Tf "$next_link" "$base/current"
  fi
  false
fi

rm -f "$archive"
trap - ERR
echo "$release_id"
