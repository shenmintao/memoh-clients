#!/usr/bin/env bash
set -euo pipefail

remove_packages=false
remove_local_config=false
for arg in "$@"; do
  case "$arg" in
    --remove-packages) remove_packages=true ;;
    --remove-local-config) remove_local_config=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

cat >&2 <<'NOTICE'
First revoke this Computer in Memoh:
  https://memoh.minq.icu -> 电脑 -> 断开连接
NOTICE
read -r -p 'Continue removing the local Runtime service? [y/N] ' answer
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
  exit 0
fi

systemctl --user disable --now memoh-runtime.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/memoh-runtime.service"
systemctl --user daemon-reload
systemctl --user reset-failed

if [[ "$remove_packages" == true ]]; then
  npm uninstall -g --prefix "$HOME/.local" @memohai/runtime pi-acp
fi

if [[ "$remove_local_config" == true ]]; then
  rm -rf "$HOME/.config/memoh"
fi

echo 'Local Memoh Runtime removed. Pi sessions and provider authentication were preserved.'
