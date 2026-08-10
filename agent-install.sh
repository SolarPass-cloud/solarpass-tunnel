#!/usr/bin/env bash
# solarpass tunnel-agent installer.
#
# سایت (ارکستریتور اینباند) این اسکریپت را یک‌بار روی هر سرور مدیریت‌شده از راه
# SSH اجرا می‌کند. بعد از آن، همه‌ی عملیات تونل از طریق HTTP agent انجام می‌شود
# و دیگر SSH لازم نیست.
#
#   curl -fsSL https://raw.githubusercontent.com/SolarPass-cloud/solarpass-tunnel/main/agent-install.sh \
#     | bash -s -- --site https://api.solarpass.org --token <AGENT_TOKEN> --agent-port 19400
#
# نصب باینری را خودش انجام نمی‌دهد: `install.sh` همان ریپو این کار را از قبل
# درست انجام می‌دهد (دانلود از Releases، تنظیم BBR، ساخت wrapper آپدیت، مهاجرت
# نصب‌های قدیمی). دوباره‌نویسی آن منطق یعنی دو مسیر نصب که با هم واگرا می‌شوند.
# پس اینجا فقط: باینری هست؟ اگر نه install.sh را صدا بزن — بعد agent را تنظیم کن.
#
# idempotent است: ناوگان ترکیبی است (بعضی سرورها از قبل باینری دارند) و
# ارکستریتور برای تعمیرِ یک agent خراب همین را دوباره اجرا می‌کند.
set -euo pipefail

REPO_DEFAULT="SolarPass-cloud/solarpass-tunnel"
BRANCH_DEFAULT="main"
BIN_DIR="/usr/local/bin"
BIN_PATH="${BIN_DIR}/solarpass-tun"

SITE=""
TOKEN=""
AGENT_PORT="19400"
PUBLIC_IP=""
REPO="${SOLARPASS_TUN_REPO:-$REPO_DEFAULT}"
BRANCH="${SOLARPASS_TUN_INSTALL_BRANCH:-$BRANCH_DEFAULT}"
# اختیاری: نصبِ باینری از یک URL مشخص به‌جای install.sh ریپو.
BINARY_URL="${SOLARPASS_TUN_AGENT_BINARY_URL:-}"
# اختیاری، فقط برای ریپوی خصوصی.
GITHUB_TOKEN="${SOLARPASS_TUN_GITHUB_TOKEN:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site)         SITE="$2"; shift 2 ;;
    --token)        TOKEN="$2"; shift 2 ;;
    --agent-port)   AGENT_PORT="$2"; shift 2 ;;
    --public-ip)    PUBLIC_IP="$2"; shift 2 ;;
    --repo)         REPO="$2"; shift 2 ;;
    --install-branch) BRANCH="$2"; shift 2 ;;
    --binary-url)   BINARY_URL="$2"; shift 2 ;;
    --github-token) GITHUB_TOKEN="$2"; shift 2 ;;
    # پذیرفته ولی نادیده گرفته می‌شود: install.sh همیشه آخرین release را می‌گیرد.
    --release-tag)  shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SITE" || -z "$TOKEN" ]]; then
  echo "error: --site and --token are required" >&2
  exit 2
fi
if [[ "$(id -u)" != "0" ]]; then
  echo "error: must run as root" >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates >/dev/null 2>&1 || true
  fi
  command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }
fi

# ── باینری ─────────────────────────────────────────────────────────────────
# اگر از قبل هست دست نمی‌زنیم: ناوگان ترکیبی است و یک سرورِ در حال کار نباید
# فقط به‌خاطر نصب agent باینریِ تونلش عوض شود. آپدیت کار جداگانه‌ای است
# (`solarpass-tun-update`).
if [[ -x "$BIN_PATH" ]]; then
  echo "==> solarpass-tun already installed ($("$BIN_PATH" --version 2>/dev/null || echo unknown))"
elif [[ -n "$BINARY_URL" ]]; then
  case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac
  url="${BINARY_URL//\{arch\}/$ARCH}"
  echo "==> downloading ${url}"
  tmp="$(mktemp)"
  if [[ -n "$GITHUB_TOKEN" ]]; then
    curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/octet-stream" "$url" -o "$tmp"
  else
    curl -fsSL --retry 3 "$url" -o "$tmp"
  fi
  install -m 0755 "$tmp" "$BIN_PATH"
  rm -f "$tmp"
else
  echo "==> installing solarpass-tun via the repo installer"
  curl -fsSL "https://raw.githubusercontent.com/${REPO}/${BRANCH}/install.sh" | bash -s -- install
fi

[[ -x "$BIN_PATH" ]] || { echo "error: solarpass-tun was not installed" >&2; exit 1; }

# ── فایروال ────────────────────────────────────────────────────────────────
# بدون این، سایت هرگز به agent نمی‌رسد و همه‌چیز «unreachable» تشخیص داده می‌شود.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "==> opening ${AGENT_PORT}/tcp in ufw"
  ufw allow "${AGENT_PORT}/tcp" >/dev/null 2>&1 || true
fi

# ── agent ──────────────────────────────────────────────────────────────────
# نوشتن پیکربندی + نصب و راه‌اندازی واحد systemd را خودِ باینری انجام می‌دهد تا
# محتوای واحد یک‌جا (در کد Rust) تعریف شده باشد و بین نصب‌کننده و برنامه واگرا نشود.
echo "==> configuring agent"
"$BIN_PATH" agent setup \
  --site "$SITE" \
  --token "$TOKEN" \
  --port "$AGENT_PORT" \
  --public-ip "$PUBLIC_IP"

# تأیید اینکه سرویس واقعاً بالا آمده. نصبی که در سکوت شکست بخورد بدترین حالت
# است: ارکستریتور آن را «نصب‌شده» می‌بیند و برای همیشه منتظر heartbeat می‌ماند.
sleep 2
if systemctl is-active --quiet solarpass-agent; then
  echo
  echo "✓ tunnel agent is running on port ${AGENT_PORT}"
else
  echo "error: solarpass-agent failed to start" >&2
  systemctl status solarpass-agent --no-pager --lines 20 >&2 || true
  exit 1
fi
