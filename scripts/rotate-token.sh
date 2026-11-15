#!/usr/bin/env bash
# 换 token：生成新的写进 .env，重启服务，不把 token 打印到屏幕。
# token 泄了（贴进聊天框、进了 shell history、截图里出现过）就跑这个。
# 用法：sudo bash scripts/rotate-token.sh

set -euo pipefail

ENV_FILE=/opt/android-mcp/.env

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 跑：sudo bash scripts/rotate-token.sh" >&2
    exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "找不到 $ENV_FILE，先跑 scripts/install.sh" >&2
    exit 1
fi

NEW_TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
cp -a "$ENV_FILE" "${ENV_FILE}.bak"
sed -i "s|^ANDROID_MCP_TOKEN=.*|ANDROID_MCP_TOKEN=${NEW_TOKEN}|" "$ENV_FILE"
chmod 600 "$ENV_FILE" "${ENV_FILE}.bak"

LEN=$(grep -E '^ANDROID_MCP_TOKEN=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]' | wc -c | tr -d ' ')
echo "✓ 新 token 已写入 $ENV_FILE，长度 ${LEN}（旧的在 ${ENV_FILE}.bak）"

if systemctl list-unit-files android-mcp-bridge.service >/dev/null 2>&1; then
    systemctl restart android-mcp-bridge 2>/dev/null \
        && echo "✓ android-mcp-bridge 已重启" \
        || echo "服务还没部署或重启失败，跳过"
else
    echo "服务还没部署，不用重启"
fi

cat <<'NEXT'

新 token 自己读，不要整段复制终端输出：
  sudo grep ANDROID_MCP_TOKEN /opt/android-mcp/.env

两端 Header 要同步换成新的，换完手机会自己重连：
  安卓 Portal → Reverse Connection → Authorization: Bearer <新 token>
  Aru    → 设置 → 连接 → MCP → 该服务 → Authorization: Bearer <新 token>

确认旧的已失效以后删备份：
  sudo rm /opt/android-mcp/.env.bak
NEXT
