#!/usr/bin/env bash
# 国内网络下载不到 GitHub release 的 apk 时用这个：
# VPS 把 apk 拉下来，在 Caddy 的 android 站点块里临时开一个带随机路径的下载地址。
#
#   sudo bash scripts/serve-apk.sh            ← 下载并开放
#   sudo bash scripts/serve-apk.sh --stop     ← 装完关掉并清干净
#
# 路径带 24 字节随机串，没有这串猜不到；但它不是鉴权，装完就 --stop。

set -euo pipefail

APP_DIR=/opt/android-mcp
PUBLIC_DIR="$APP_DIR/public"
STATE_FILE="$APP_DIR/.apk-dl-token"
URL_FILE="$APP_DIR/.apk-url"
PATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/caddy_apk_patch.py"

PORTAL_VERSION="${PORTAL_VERSION:-0.8.2}"
APK_NAME="com.mobilerun.portal-${PORTAL_VERSION}.apk"
APK_URL="https://github.com/droidrun/mobilerun-portal/releases/download/v${PORTAL_VERSION}/${APK_NAME}"
# 官方 release 资源公布的 sha256（0.8.2）
APK_SHA256="bee2872917ff5cdb24641738fe09a88df1e252a712247044c3d13a544dcc12d8"

HOST="$(grep -E '^ANDROID_MCP_PUBLIC_HOST=' "$APP_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')"
HOST="${HOST:-android.vesperphosphor.online}"

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 跑：sudo bash scripts/serve-apk.sh" >&2
    exit 1
fi

reload_caddy() {
    if ! caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        echo "❌ Caddyfile 校验失败，已回滚" >&2
        [ -f /etc/caddy/Caddyfile.bak-apk ] && cp -a /etc/caddy/Caddyfile.bak-apk /etc/caddy/Caddyfile
        exit 1
    fi
    systemctl reload caddy
}

if [ "${1:-}" = "--stop" ]; then
    python3 "$PATCH" "$HOST" --remove
    reload_caddy
    # apk、随机串、写下的完整地址，以及 patch 留的 Caddyfile 备份都要清
    # （备份里嵌着那个随机串，留着没意义）
    rm -rf "$PUBLIC_DIR" "$STATE_FILE" "$URL_FILE" /etc/caddy/Caddyfile.bak-apk
    echo "✓ 下载路径已关闭。apk、随机串、.apk-url 和 Caddyfile.bak-apk 已删。"
    echo "  桥本身不受影响。"
    if grep -q '/dl/' /etc/caddy/Caddyfile; then
        echo "⚠ /etc/caddy/Caddyfile 里还有 /dl/ 字样，自己看一眼" >&2
    else
        echo "✓ Caddyfile 里已无 /dl/ 路径"
    fi
    exit 0
fi

mkdir -p "$PUBLIC_DIR"

if [ -f "$PUBLIC_DIR/$APK_NAME" ] \
    && echo "${APK_SHA256}  $PUBLIC_DIR/$APK_NAME" | sha256sum -c --status 2>/dev/null; then
    echo "=== apk 已在本地且校验通过，跳过下载 ==="
else
    echo "=== 1. 下载 apk（${PORTAL_VERSION}，54MB，慢的话等一下）==="
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
        -o "$PUBLIC_DIR/$APK_NAME" "$APK_URL"; then
        echo "❌ VPS 也下不来。试试代理，或换个镜像源：" >&2
        echo "   curl -fL -o $PUBLIC_DIR/$APK_NAME https://ghproxy.net/$APK_URL" >&2
        exit 1
    fi

    echo "=== 2. 校验 sha256 ==="
    if ! echo "${APK_SHA256}  $PUBLIC_DIR/$APK_NAME" | sha256sum -c -; then
        echo "❌ 指纹不对，已删除。不要装这个文件。" >&2
        rm -f "$PUBLIC_DIR/$APK_NAME"
        exit 1
    fi
fi

if [ -f "$STATE_FILE" ]; then
    DL_TOKEN="$(cat "$STATE_FILE")"
else
    DL_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
    printf '%s' "$DL_TOKEN" > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
fi

echo "=== 3. 在 Caddy 里开临时下载路径 ==="
python3 "$PATCH" "$HOST" "$DL_TOKEN"
reload_caddy

chmod 755 "$PUBLIC_DIR"
chmod 644 "$PUBLIC_DIR/$APK_NAME"

URL="https://${HOST}/dl/${DL_TOKEN}/${APK_NAME}"
printf '%s\n' "$URL" > "$URL_FILE"
chmod 600 "$URL_FILE"

echo
echo "=== 开好了 ==="
echo "自己读完整地址，用手机浏览器打开："
echo "  cat $URL_FILE"
echo
echo "本地自检（请求头 1KB，返回 206 Partial Content 就是对的）："
curl -s -o /dev/null -w '  HTTP %{http_code}  %{size_download} bytes\n' -r 0-1023 "$URL" || true
echo
echo "装完立刻关掉："
echo "  sudo bash scripts/serve-apk.sh --stop"
