#!/usr/bin/env bash
set -euo pipefail
server="${MEMOH_SERVER:?Set MEMOH_SERVER to your Memoh API URL}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
node_bin="$(command -v node)"
command -v npm >/dev/null
command -v swiftc >/dev/null
test "$(node -p 'Number(process.versions.node.split(".")[0])')" -ge 22
npm install -g --prefix "$HOME/.local" \
  "${MEMOH_RUNTIME_PACKAGE:-$script_dir/../../artifacts/runtime.tgz}" \
  "${MEMOH_PI_ACP_PACKAGE:-$script_dir/../../artifacts/pi-acp.tgz}" \
  '@earendil-works/pi-coding-agent@0.85.0'
umask 077
mkdir -p "$HOME/.memoh" "$HOME/Library/LaunchAgents" "$HOME/Library/Application Support/Memoh"
IFS= read -r -s -p 'Paste this machine’s mrk_... Runtime Key: ' runtime_key
echo
printf '%s' "$runtime_key" > "$HOME/.memoh/runtime-key"
unset runtime_key
chmod 600 "$HOME/.memoh/runtime-key"
node --input-type=module - "$server" <<'NODE'
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path';
fs.writeFileSync(path.join(os.homedir(),'.memoh/runtime.json'),JSON.stringify({server:process.argv[2],name:os.hostname()}),{mode:0o600});
NODE
cp "$script_dir/runtime-launcher.mjs" "$HOME/.memoh/runtime-launcher.mjs"
python3 - "$node_bin" <<'PY'
import os, pathlib, plistlib, sys
home=pathlib.Path.home()
p=home/'Library/LaunchAgents/icu.minq.memoh.runtime.plist'
config={'Label':'icu.minq.memoh.runtime','ProgramArguments':[sys.argv[1],str(home/'.memoh/runtime-launcher.mjs')],'RunAtLoad':True,'KeepAlive':True,'WorkingDirectory':str(home),'EnvironmentVariables':{'PATH':str(home/'.local/bin')+':'+os.environ['PATH']},'StandardOutPath':str(home/'.memoh/runtime.log'),'StandardErrorPath':str(home/'.memoh/runtime.log')}
p.write_bytes(plistlib.dumps(config));p.chmod(0o600)
PY
service="gui/$(id -u)/icu.minq.memoh.runtime"
if launchctl print "$service" >/dev/null 2>&1; then launchctl bootout "$service"; fi
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/icu.minq.memoh.runtime.plist"
swiftc "$script_dir/MemohMenuBar.swift" -o "$HOME/Library/Application Support/Memoh/MemohMenuBar"
open "$HOME/Library/Application Support/Memoh/MemohMenuBar"
echo 'Runtime installed. The menu can be reopened from ~/Library/Application Support/Memoh.'
