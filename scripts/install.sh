#!/usr/bin/env bash
# 装运行时：/opt/android-mcp + venv + 依赖 + .env
# 不碰 Nginx / Caddy / systemd——那三样手动来，按 README 第 2 / 3 步。
# 用法：sudo bash scripts/install.sh

set -euo pipefail

APP_DIR=/opt/android-mcp
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_NAME=android_mcp_bridge_vps.py

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 跑：sudo bash scripts/install.sh" >&2
    exit 1
fi

for f in "$SCRIPT_NAME" requirements.txt .env.example; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        echo "仓库里找不到 $f，当前目录：$SRC_DIR" >&2
        exit 1
    fi
done

read_token() {
    grep -E '^ANDROID_MCP_TOKEN=' "$APP_DIR/.env" | head -1 | cut -d= -f2- | tr -d '[:space:]'
}

echo "=== 1. 建目录 ==="
mkdir -p "$APP_DIR"

echo "=== 2. 复制脚本 ==="
install -m 644 "$SRC_DIR/$SCRIPT_NAME" "$APP_DIR/$SCRIPT_NAME"
install -m 644 "$SRC_DIR/requirements.txt" "$APP_DIR/requirements.txt"
echo "$APP_DIR/$SCRIPT_NAME"

echo "=== 3. venv 与依赖 ==="
if [ ! -x "$APP_DIR/.venv/bin/python" ]; then
    python3 -m venv "$APP_DIR/.venv"
fi
"$APP_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/.venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"
"$APP_DIR/.venv/bin/pip" list 2>/dev/null | grep -Ei '^(websockets|mcp|uvicorn) ' || true

echo "=== 4. .env ==="
if [ -f "$APP_DIR/.env" ]; then
    echo "$APP_DIR/.env 已存在，不覆盖。"
    echo "当前 token 长度：$(read_token | wc -c | tr -d ' ')（小于 16 服务会拒绝启动）"
    echo "要换 token 就跑：sudo bash scripts/rotate-token.sh"
else
    NEW_TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
    sed "s|^ANDROID_MCP_TOKEN=.*|ANDROID_MCP_TOKEN=${NEW_TOKEN}|" "$SRC_DIR/.env.example" > "$APP_DIR/.env"
    echo "已生成 $APP_DIR/.env，token 随机 32 字节。"
fi
chmod 600 "$APP_DIR/.env"
chown root:root "$APP_DIR/.env"
ls -l "$APP_DIR/.env"

echo "=== 5. 语法检查 ==="
"$APP_DIR/.venv/bin/python" -m py_compile "$APP_DIR/$SCRIPT_NAME"
echo "✓ py_compile 通过"

echo "=== 6. 依赖导入检查 ==="
"$APP_DIR/.venv/bin/python" - <<'PY'
import importlib.metadata as md
import websockets, uvicorn
from mcp.server.fastmcp import FastMCP, Image
from mcp.server.transport_security import TransportSecuritySettings
try:
    mcp_ver = md.version("mcp")
except Exception:
    mcp_ver = "?"
print("websockets", websockets.__version__, "/ mcp", mcp_ver, "/ uvicorn", uvicorn.__version__)
print("✓ 四个 import 全部成功")
PY

echo
echo "=== 装完了 ==="
cat <<'NEXT'
token 在 /opt/android-mcp/.env 里，要看就自己 cat，本脚本不再把它打印到屏幕上。
终端输出很容易被整段复制贴走，token 就跟着泄了：
  sudo grep ANDROID_MCP_TOKEN /opt/android-mcp/.env

下一步（README 第 2 / 3 步）：
  网关二选一 —— Caddy 用 deploy/Caddyfile.snippet，Nginx 用 deploy/android-bridge.nginx.conf
  systemd  —— sudo cp deploy/android-mcp-bridge.service /etc/systemd/system/
              sudo systemctl daemon-reload
              sudo systemctl enable --now android-mcp-bridge
本脚本没有改过 Nginx / Caddy / systemd。
NEXT
