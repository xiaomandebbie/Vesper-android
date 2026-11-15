#!/usr/bin/env bash
# 只读体检：不安装、不修改、不重启任何东西。
# 用法：bash scripts/preflight.sh

set -u

DOMAIN="${ANDROID_MCP_PUBLIC_HOST:-android.vesperphosphor.online}"
WS_PORT="${ANDROID_MCP_WS_PORT:-18765}"
HTTP_PORT="${ANDROID_MCP_HTTP_PORT:-18766}"

say() { printf '\n=== %s ===\n' "$1"; }

say "1. 系统"
uname -a
[ -r /etc/os-release ] && . /etc/os-release && echo "os: ${PRETTY_NAME:-unknown}"
echo "whoami: $(whoami)"

say "2. 80 / 443 是谁在听"
# 这一步决定用 Caddy 还是 Nginx。两个都在的话，听 443 的那个说话算数。
if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep -E ':(80|443)\b' || echo "80/443 没有人听"
else
    echo "没有 ss，试 netstat"
    netstat -ltnp 2>/dev/null | grep -E ':(80|443)\b' || echo "80/443 没有人听"
fi

say "3. 网关装了哪些"
for svc in caddy nginx; do
    if command -v "$svc" >/dev/null 2>&1; then
        printf '%s: 已安装 ' "$svc"
        "$svc" version 2>/dev/null | head -1 || "$svc" -v 2>&1 | head -1
        printf '%s systemd: ' "$svc"
        systemctl is-active "$svc" 2>/dev/null || true
    else
        echo "$svc: 未安装"
    fi
done

say "4. 目标端口 ${WS_PORT} / ${HTTP_PORT} 是否空闲"
for p in "$WS_PORT" "$HTTP_PORT"; do
    hit=$(ss -ltnp 2>/dev/null | grep -E ":${p}\b" || true)
    if [ -n "$hit" ]; then
        echo "❌ ${p} 已被占用："
        echo "$hit"
    else
        echo "✓ ${p} 空闲"
    fi
done
echo
echo "参考：这台机器已知已占用 8787(Aru Host) 8888/6873(Uranus) 3001 3002 3003 3011 3020 8791 9090 18001"

say "5. Python"
if command -v python3 >/dev/null 2>&1; then
    python3 --version
    python3 -c 'import sys; print("3.9+ 满足" if sys.version_info >= (3, 9) else "❌ 低于 3.9，要升级")'
    python3 -c 'import venv' 2>/dev/null && echo "venv: 可用" || echo "❌ venv 不可用，装 python3-venv"
else
    echo "❌ 没有 python3"
fi

say "6. DNS：${DOMAIN} 解到哪"
if command -v dig >/dev/null 2>&1; then
    dig +short "$DOMAIN" A | sed 's/^/A: /' || true
    [ -z "$(dig +short "$DOMAIN" A)" ] && echo "❌ 没有 A 记录，先去 DNS 加"
elif command -v getent >/dev/null 2>&1; then
    getent hosts "$DOMAIN" || echo "❌ 解不开，先去 DNS 加 A 记录"
else
    echo "没有 dig / getent，跳过"
fi
echo "本机公网 IP（要和上面的 A 记录一致）："
curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "（取不到，忽略）"
echo

say "7. 现成证书"
if [ -d /etc/letsencrypt/live ]; then
    ls -1 /etc/letsencrypt/live 2>/dev/null | sed 's/^/letsencrypt: /'
else
    echo "没有 /etc/letsencrypt/live（Caddy 自己管证书的话这是正常的）"
fi
if [ -d /var/lib/caddy/.local/share/caddy/certificates ]; then
    find /var/lib/caddy/.local/share/caddy/certificates -name '*.crt' 2>/dev/null \
        | sed 's/^/caddy cert: /' | head -20
fi
command -v certbot >/dev/null 2>&1 && certbot --version 2>&1 | sed 's/^/certbot: /' || echo "certbot: 未安装"

say "8. 桥自己装过没有"
[ -d /opt/android-mcp ] && ls -la /opt/android-mcp || echo "/opt/android-mcp 不存在（首次安装是正常的）"
systemctl is-enabled android-mcp-bridge 2>/dev/null | sed 's/^/service enabled: /' || echo "service: 未安装"

say "体检完成"
cat <<'TIP'
把上面整段贴回给小克。关键是两件事：
  · 443 是 Caddy 还是 Nginx 在听  → 决定第 2 步用 deploy/ 里哪一份配置
  · 18765 / 18766 空不空闲        → 被占就换号，别和现有服务抢
本脚本没有修改任何文件。
TIP
