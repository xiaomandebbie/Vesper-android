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
    TOKEN_LEN=$(grep -E '^ANDROID_MCP_TOKEN=' "$APP_DIR/.env" | head -1 | cut -d= -f2- | tr -d '[:space:]' | wc -c)
    echo "当前 token 长度：$((TOKEN_LEN > 0 ? TOKEN_LEN - 1 : 0))（小于 16 服务会拒绝启动）"
else
    NEW_TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
    sed "s|^ANDROID_MCP_TOKEN=.*|ANDROID_MCP_TOKEN=${NEW_TOKEN}|" "$SRC_DIR/.env.example" > "$APP_DIR/.env"
    echo "已生成 $APP_DIR/.env，token 随机 32 位。"
fi
chmod 600 "$APP_DIR/.env"
chown root:root "$APP_DIR/.env"
ls -l "$APP_DIR/.env"

echo "=== 5. 语法检查 ==="
"$APP_DIR/.venv/bin/python" -m py_compile "$APP_DIR/$SCRIPT_NAME"
echo "✓ py_compile 通过"

echo "=== 6. 依赖导入检查 ==="
"$APP_DIR/.venv/bin/python" - <<'PY'
import websockets, uvicorn
from mcp.server.fastmcp import FastMCP, Image
from mcp.server.transport_security import TransportSecuritySettings
import mcp
print("websockets", websockets.__version__, "/ mcp", getattr(mcp, "__version__", "?"))
print("✓ 四个 import 全部成功")
PY

echo
echo "=== 装完了 ==="
echo "你的 token（只在终端看，不要粘进聊天框）："
grep -E '^ANDROID_MCP_TOKEN=' "$APP_DIR/.env" | cut -d= -f2-
echo
cat <<'NEXT'
下一步（README 第 2 / 3 步）：
  网关二选一 —— Caddy 用 deploy/Caddyfile.snippet，Nginx 用 deploy/android-bridge.nginx.conf
  systemd  —— sudo cp deploy/android-mcp-bridge.service /etc/systemd/system/
              sudo systemctl daemon-reload
              sudo systemctl enable --now android-mcp-bridge
本脚本没有改过 Nginx / Caddy / systemd。
NEXT
