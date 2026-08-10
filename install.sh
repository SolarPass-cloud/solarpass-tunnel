#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────
#  SolarPass Tunnel — installer / updater
#
#  install:  curl -fsSL https://raw.githubusercontent.com/SolarPass-cloud/solarpass-tunnel/main/install.sh | sudo bash
#  update:   sudo solarpass-tun-update
#
#  This script downloads the latest released binary from GitHub Releases (public
#  repo), installs it into /usr/local/bin, tunes the network, and creates a
#  simple update command.
# ────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO="SolarPass-cloud/solarpass-tunnel"
BRANCH="main"                      # branch the public install.sh lives on (for updates)
BIN_DIR="/usr/local/bin"
BIN_PATH="${BIN_DIR}/solarpass-tun"
UPDATE_WRAPPER="${BIN_DIR}/solarpass-tun-update"
ASSET_PREFIX="solarpass-tun-linux"   # final asset: solarpass-tun-linux-amd64 / -arm64

# ── colors ──
if [ -t 1 ]; then
  C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_B="\033[36m"; C_0="\033[0m"
else
  C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""
fi
say()  { echo -e "${C_B}▸${C_0} $*"; }
ok()   { echo -e "${C_G}✔${C_0} $*"; }
warn() { echo -e "${C_Y}!${C_0} $*"; }
die()  { echo -e "${C_R}✗${C_0} $*" >&2; exit 1; }

SUBCMD="${1:-install}"

# ── must be root ──
[ "$(id -u)" -eq 0 ] || die "This script must be run as root (use sudo)."

# ── detect architecture ──
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "Unsupported architecture: $(uname -m) (only amd64 and arm64)" ;;
  esac
}

# ── base dependencies ──
ensure_deps() {
  local need=()
  command -v curl >/dev/null 2>&1 || need+=(curl)
  if [ "${#need[@]}" -gt 0 ]; then
    say "Installing required tools: ${need[*]}"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y -qq "${need[@]}"
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y -q "${need[@]}"
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q "${need[@]}"
    else
      die "Unknown package manager. Please install manually: ${need[*]}"
    fi
  fi
}

# ── download the latest binary from Releases ──
download_binary() {
  local arch asset url tmp
  arch="$(detect_arch)"
  asset="${ASSET_PREFIX}-${arch}"
  url="https://github.com/${REPO}/releases/latest/download/${asset}"
  tmp="$(mktemp)"

  say "Downloading ${asset} ..."
  if ! curl -fSL --retry 3 -o "$tmp" "$url"; then
    rm -f "$tmp"
    die "Download failed. Is there a release published for ${arch}? ($url)"
  fi

  install -m 0755 "$tmp" "$BIN_PATH"
  rm -f "$tmp"
  ok "Binary installed at ${BIN_PATH}."
}

# ── network tuning (BBR + buffers) — install only ──
tune_network() {
  local sysctl_file="/etc/sysctl.d/99-solarpass-tun.conf"
  say "Applying network tuning (BBR)..."
  cat > "$sysctl_file" <<'EOF'
# SolarPass Tunnel network tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
EOF
  sysctl -p "$sysctl_file" >/dev/null 2>&1 || warn "sysctl not fully applied (harmless)."
  ok "Network tuning applied."
}

# ── create the simple update command ──
install_update_wrapper() {
  cat > "$UPDATE_WRAPPER" <<EOF
#!/usr/bin/env bash
# Update SolarPass Tunnel to the latest version.
curl -fsSL https://raw.githubusercontent.com/${REPO}/${BRANCH}/install.sh | sudo bash -s -- update
EOF
  chmod 0755 "$UPDATE_WRAPPER"
}

# ── retire the old skypass-named install ──
# The new binary migrates saved tunnels and their systemd units on first run
# (menu / restart-all), so this only removes the leftover executables and the
# superseded sysctl drop-in — never config or units.
cleanup_legacy() {
  local removed=0
  for f in \
    "${BIN_DIR}/skypass-tun" \
    "${BIN_DIR}/skypass-tun-update" \
    /etc/sysctl.d/99-skypass-tun.conf \
    /etc/sysctl.d/99-skypass.conf
  do
    if [ -e "$f" ]; then rm -f "$f"; removed=1; fi
  done
  [ "$removed" = "1" ] && say "Removed the old skypass-tun install (tunnels are migrated on first run)."
  return 0
}

# ── restart the management agent, if this box has one ──
# The agent (installed by agent-install.sh, used by the inbound orchestrator) is
# a systemd unit of its own, so `restart-all` — which only covers tunnels — does
# not touch it. Without this it keeps running the OLD binary after an update and
# reports a stale version to the panel while the tunnels are already current.
restart_agent() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl list-unit-files 2>/dev/null | grep -q '^solarpass-agent\.service' || return 0
  if systemctl restart solarpass-agent >/dev/null 2>&1; then
    ok "Management agent restarted on the new version."
  else
    warn "Agent restart failed; run: systemctl restart solarpass-agent"
  fi
}

banner() {
  echo ""
  echo -e "${C_B}  ☁️  SolarPass Tunnel${C_0}"
  echo -e "  ──────────────────────────────"
  echo ""
}

case "$SUBCMD" in
  install)
    banner
    ensure_deps
    download_binary
    tune_network
    install_update_wrapper
    # A re-run over an existing skypass install must migrate it, not just drop a
    # new binary next to it: `restart-all` is what moves the configs and rewrites
    # the systemd units. On a truly fresh box there is nothing saved and this is
    # a no-op, so it is safe to always call. Only then is the old binary removed.
    if "$BIN_PATH" restart-all >/dev/null 2>&1; then
      ok "Existing tunnels migrated and restarted on the new version."
    fi
    restart_agent
    cleanup_legacy
    echo ""
    ok "Installation complete!"
    echo ""
    echo -e "  To get started, run:  ${C_G}solarpass-tun${C_0}"
    echo -e "  To update later:      ${C_G}sudo solarpass-tun-update${C_0}"
    echo ""
    ;;
  update)
    banner
    ensure_deps
    download_binary
    # Refresh the wrapper too: an install from before the rename still points at
    # the old repo, so without this the next `solarpass-tun-update` would 404.
    install_update_wrapper
    # restart-all also migrates any tunnels left over from a skypass install,
    # so the old binary is only removed afterwards.
    if "$BIN_PATH" restart-all >/dev/null 2>&1; then
      ok "Saved tunnels restarted on the new version."
    fi
    restart_agent
    cleanup_legacy
    ok "Update complete."
    ;;
  *)
    die "Unknown subcommand: ${SUBCMD} (only install or update)"
    ;;
esac
