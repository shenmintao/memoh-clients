#!/usr/bin/env bash
set -euo pipefail

SERVER="${MEMOH_SERVER:?Set MEMOH_SERVER to your Memoh API URL}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_PACKAGE="${MEMOH_RUNTIME_PACKAGE:-$script_dir/../../artifacts/runtime.tgz}"
PI_ACP_PACKAGE="${MEMOH_PI_ACP_PACKAGE:-$script_dir/../../artifacts/pi-acp.tgz}"
MACHINE_NAME="${MEMOH_MACHINE_NAME:-$(hostname)}"
RUNTIME_VERSION="${MEMOH_RUNTIME_VERSION:-0.19.0-local-capabilities.1}"
PI_ACP_VERSION="${PI_ACP_VERSION:-0.0.33-local-mcp.1}"
PI_VERSION="${PI_VERSION:-0.85.0}"

for command in node npm systemctl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
if [[ "$node_major" -lt 22 ]]; then
  echo "Node.js 22 or newer is required; found $(node --version)." >&2
  exit 1
fi

if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "The systemd user manager is unavailable. Log in normally and retry." >&2
  exit 1
fi

echo "Installing tested Memoh/Pi packages into $HOME/.local..."
npm install -g --prefix "$HOME/.local" \
  "$RUNTIME_PACKAGE" \
  "$PI_ACP_PACKAGE" \
  "@earendil-works/pi-coding-agent@${PI_VERSION}"

runtime_command="$HOME/.local/bin/memoh-runtime"
for command in "$runtime_command" "$HOME/.local/bin/pi-acp" "$HOME/.local/bin/pi"; do
  if [[ ! -x "$command" ]]; then
    echo "Expected command was not installed: $command" >&2
    exit 1
  fi
done
node_dir="$(dirname "$(command -v node)")"
service_path="$HOME/.local/bin:$node_dir:/usr/local/bin:/usr/bin:/bin"

config_dir="$HOME/.config/memoh"
service_dir="$HOME/.config/systemd/user"
mkdir -p "$config_dir" "$service_dir"
chmod 700 "$config_dir"

cat >&2 <<'NOTICE'
Create a NEW Computer credential in Memoh before continuing:
  Your Memoh server -> 电脑 -> 连接其他电脑
Each machine and each OS user account must use its own mrk_... key.
NOTICE
IFS= read -r -s -p 'Paste only the mrk_... Runtime Key: ' runtime_key
echo
if [[ ! "$runtime_key" =~ ^mrk_[A-Za-z0-9]+$ ]]; then
  echo "The Runtime Key format is invalid." >&2
  exit 1
fi

umask 077
printf 'MEMOH_RUNTIME_KEY=%s\n' "$runtime_key" > "$config_dir/runtime.env"
unset runtime_key
cat > "$config_dir/runtime.json" <<EOF
{
  "name": "${MACHINE_NAME}",
  "server": "${SERVER}",
  "runtime_version": "${RUNTIME_VERSION}",
  "pi_acp_version": "${PI_ACP_VERSION}",
  "pi_version": "${PI_VERSION}"
}
EOF
chmod 600 "$config_dir/runtime.env" "$config_dir/runtime.json"

cat > "$service_dir/memoh-runtime.service" <<EOF
[Unit]
Description=Memoh Remote Runtime
Documentation=https://github.com/shenmintao/memoh-clients
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment=MEMOH_RUNTIME_SERVER=${SERVER}
Environment=PATH=${service_path}
EnvironmentFile=%h/.config/memoh/runtime.env
ExecStart=${runtime_command}
Restart=always
RestartSec=5
TimeoutStopSec=15

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now memoh-runtime.service
sleep 3
systemctl --user --no-pager --full status memoh-runtime.service || true

echo
echo "Logs: journalctl --user -u memoh-runtime.service -f"
echo "Return to Memoh and wait for '${MACHINE_NAME}' to become Online."
echo "Then run 'pi' or 'pi-acp --terminal-login' once to configure model authentication on this machine."
echo "For service startup while logged out, optionally run: sudo loginctl enable-linger '$USER'"
