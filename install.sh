#!/bin/zsh
# Install Playwright MCP (pinned, package-lock.json) and write the extension's
# hidden-origins.json from bridge.env. Re-run after changing either.
emulate -L zsh
set -e
B=${0:A:h}
[[ -r $B/bridge.env ]] || { cp $B/bridge.env.example $B/bridge.env; print "wrote $B/bridge.env from the example; edit it, then re-run"; }
source $B/bridge.env
node=${BRIDGE_NODE:-$(command -v node)}
[[ -x $node ]] || { print -u2 "install.sh: no node 20+ (install one, or set BRIDGE_NODE in bridge.env)"; exit 1; }
(( ${$($node -p 'process.versions.node')%%.*} >= 20 )) || { print -u2 "install.sh: node 20+ needed"; exit 1; }
PATH=${node:h}:$PATH npm ci --prefix $B --omit=dev --no-audit --no-fund
# The extension can only read files in its own folder.
ext=${BRIDGE_EXTENSION_DIR:-$B/extension}
/usr/bin/python3 - ${~ext}/hidden-origins.json "$BRIDGE_HIDDEN_ORIGINS" <<'PY'
import json, sys
origins = [o.strip().rstrip("/") for o in sys.argv[2].split(";") if o.strip()]
json.dump(origins, open(sys.argv[1], "w"))
print(f"{sys.argv[1]}: {len(origins)} hidden origin(s)")
PY
print "Installed. In Arc, in each profile to drive: arc://extensions → Developer mode →"
print "Load unpacked → ${~ext}; then: $B/bin/browser-bridge init-token '<profile dir>'"
