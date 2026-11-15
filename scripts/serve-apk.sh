#!/usr/bin/env bash
# 国内网络下载不到 GitHub release 的 apk 时用这个：
# VPS 把 apk 拉下来，在 Caddy 的 android 站点块里临时开一个带随机路径的下载地址。
#
#   sudo bash scripts/serve-apk.sh            ← 下载并开放
#   sudo bash scripts/serve-apk.sh --stop     ← 装完关掉
#
# 路径带 24 字节随机串，没有这串猜不到；但它不是鉴权，装完就 --stop。

set -euo pipefail

APP_DIR=/opt/android-mcp
PUBLIC_DIR="$APP_DIR/public"
STATE_FILE="$APP_DIR/.apk-dl-token"
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
    rm -rf "$PUBLIC_DIR" "$STATE_FILE"
    echo "✓ 下载路径已关闭，apk 和随机串已删。桥本身不受影响。"
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
echo
echo "=== 开好了 ==="
echo "自己读完整地址，用手机浏览器打开："
echo "  cat $APP_DIR/.apk-url"
printf '%s\n' "$URL" > "$APP_DIR/.apk-url"
chmod 600 "$APP_DIR/.apk-url"
echo
echo "本地自检（应该返回 200）："
curl -s -o /dev/null -w '  HTTP %{http_code}  %{size_download} bytes\n' -r 0-1023 "$URL" || true
echo
echo "装完立刻关掉："
echo "  sudo bash scripts/serve-apk.sh --stop"
