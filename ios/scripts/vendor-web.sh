#!/usr/bin/env bash
# Copy the web libraries the iOS app renders with into LHRender's bundle.
# Run from anywhere after `npm ci` at the repository root:
#   ios/scripts/vendor-web.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
src="$root/node_modules/mermaid/dist/mermaid.min.js"
dest="$(cd "$here/../LHKit/Sources/LHRender/Resources/web" && pwd)/mermaid.min.js"
if [[ ! -f "$src" ]]; then
	echo "vendor-web: $src not found — run 'npm ci' at the repository root first." >&2
	exit 1
fi
cp "$src" "$dest"
version="$(node -p "require('$root/node_modules/mermaid/package.json').version" 2>/dev/null || echo unknown)"
echo "vendor-web: mermaid $version → ${dest#$root/}"
