# Vesper-android

把安卓手机接成允朔的一只手：**Aru (iPhone) → HTTPS/MCP → VPS 中转 → WSS → 安卓 Mobilerun Portal**。

原方案（Chronos × Kairos，2026-11-12）要一台 Windows 在局域网常开当中转。这个仓库把中转搬到 VPS，手机仍然要常开、联网、Portal 活着。

## 可行吗

可行，结构是对的。手机主动向外建 WSS 长连接，VPS 只是一台有公网地址的交换机——手机不需要公网 IP，Aru 和手机也不需要在同一个网里。

但照着那份 PDF 一行一行敲，会在三个地方卡住：

| 卡点 | 实情 | 这个仓库怎么处理 |
|---|---|---|
| 80/443 可能不是 Nginx 在听 | 这台机器上已经有 Caddy 把 `aru.vesperphosphor.online` 反代到 `127.0.0.1:8787`。Caddy 占着 443 的时候，`certbot --nginx` 和 nginx 都起不来 | 第 0 步先只读体检；`deploy/` 里 Caddy 和 Nginx 两份配置都给了，按体检结果选一份 |
| Host / Origin 校验 | 脚本开了 DNS rebinding 保护。Aru 作为 MCP 客户端不一定发 `Origin`，发了也不会正好是 `https://android.vesperphosphor.online` | 网关侧统一写死 `Origin`，`allowed_hosts` 补上 `:443` 变体 |
| 截图报 `1009 message too big` | PDF 让你去调 nginx 的 `proxy_buffer_size 16m`，归因错了。1009 是 WebSocket 关闭码，上限在 Python 侧的 `max_size`，和反代 buffer 无关 | buffer 调回正常值；上限做成 `ANDROID_MCP_MAX_WS_MB`，默认 16 |

最弱的一环不在 VPS 上，在手机：Portal 靠无障碍服务常驻，安卓会杀后台。手机要插着电、关掉针对它的电池优化、锁屏别清后台。这件事没有服务端解法。

端口选 18765 / 18766 是安全的。这台机器已经占掉的：8787（Aru Host，systemd）、8888 和 6873（Uranus）、3001 / 3002 / 3003 / 3011 / 3020 / 8791 / 9090 / 18001（pm2 那一批）。

## 连接结构

```
iPhone (Aru)
  │ HTTPS  https://android.vesperphosphor.online/mcp
  ▼
VPS 网关（Caddy 或 Nginx，TLS 在这里终止）
  ├─ /mcp          → 127.0.0.1:18766   uvicorn / MCP streamable HTTP
  └─ /android/join → 127.0.0.1:18765   WebSocket
                          ▲
                          │ WSS（公网加密）
                   安卓 Mobilerun Portal（反向连接）
```

两个内部端口只监听 `127.0.0.1`，**不要**在安全组里开放，也不要让脚本绑 `0.0.0.0`。

## 文件

```
android_mcp_bridge_vps.py          桥本体，WS 收手机 + MCP 对 Aru
.env.example                       配置模版（真 .env 不进仓库）
requirements.txt                   websockets 15.0.1 / mcp 1.30.0 / uvicorn
scripts/preflight.sh               第 0 步只读体检
scripts/install.sh                 装运行时，不碰网关和 systemd
deploy/Caddyfile.snippet           网关配置 A（443 在 Caddy 手里）
deploy/android-bridge.nginx.conf   网关配置 B（443 在 Nginx 手里）
deploy/android-mcp-bridge.service  systemd 单元
```

## 第 0 步：体检（只读，不改任何东西）

```bash
cd /opt
git clone https://github.com/xiaomandebbie/Vesper-android.git
cd Vesper-android
bash scripts/preflight.sh
```

它会告诉你：80/443 谁在听、18765/18766 是否空闲、Python 版本够不够、`android.vesperphosphor.online` 的 A 记录解到哪、现成证书在不在。

把输出贴给我，我按结果给下一步。第 2 步的两条路按体检结果选一条，**不要都做**。

## 第 1 步：装运行时

```bash
sudo bash scripts/install.sh
```

做四件事：建 `/opt/android-mcp`、复制脚本、建 venv 装依赖、生成 `.env`（token 自动随机 32 位，`chmod 600`）。装完跑一次 `py_compile` 和一次 import 检查，并把 token 打印在终端里——**只在终端看，不要粘到聊天里**。

它不碰 Nginx、Caddy、systemd。那三样下面手动来，每一步可逆。

## 第 2 步：网关（二选一）

### A. 这台机器用 Caddy（大概就是这种情况）

把 `deploy/Caddyfile.snippet` 的内容追加到 `/etc/caddy/Caddyfile`，然后：

```bash
caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Caddy 自己申请和续证书，不需要 certbot。前提是 A 记录已生效、80 和 443 对公网可达。

### B. 这台机器用 Nginx

```bash
sudo certbot certonly --nginx -d android.vesperphosphor.online
sudo cp deploy/android-bridge.nginx.conf /etc/nginx/conf.d/
sudo nginx -t && sudo systemctl reload nginx
```

已有 `*.vesperphosphor.online` 泛域名证书就跳过 certbot，把配置里两行 `ssl_certificate*` 换成泛域名证书的路径。

## 第 3 步：systemd

```bash
sudo cp deploy/android-mcp-bridge.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now android-mcp-bridge
sudo journalctl -u android-mcp-bridge -n 30
```

日志里应该出现：

```
PHONE (via gateway WSS): wss://android.vesperphosphor.online/android/join
MCP   (via gateway HTTPS): https://android.vesperphosphor.online/mcp
Internal ports: WS=18765 HTTP=18766 max_ws=16MB
```

单元文件写的是 `User=root`，和 `.env` 的 600 权限对得上。改成别的用户的话，`.env` 的归属要跟着改，否则 token 读成空字符串——服务起得来，但谁都连不上。

## 第 4 步：两端接进来

**安卓 Portal → Reverse Connection**

| 字段 | 值 |
|---|---|
| URL | `wss://android.vesperphosphor.online/android/join` |
| Header 名 | `Authorization` |
| Header 值 | `Bearer <token>` |

Portal 如果有单独的 Token 栏，只填 token 本身，别再加一遍 `Bearer`。日志出现 `PHONE CONNECTED` 就是手机这一半通了。

**Aru → 总设置 → 连接 → MCP → 新增服务**

| 字段 | 值 |
|---|---|
| 类型 | Streamable HTTP |
| URL | `https://android.vesperphosphor.online/mcp` |
| Header 名 | `Authorization` |
| Header 值 | `Bearer <token>` |

加完要获取工具目录、启用服务，并确认协作者设置里带上了这个服务。这一步也可以交给小克做，token 由你在手机上的输入框填，不经过对话。

## 验收顺序

1. `android_connection_status` → `connected: true`
2. `android_version` → 返回 Portal 版本号
3. `android_screenshot` → 能看到手机画面
4. `android_open_messenger app=wechat` → 微信打开了
5. 进一个测试聊天，`android_input_text` 输一句不含敏感信息的短句
6. 再截图，核对收件人和输入框里的文字
7. 你本人同意之后再发送，发完再截一张看气泡

## 工具清单

只读：`android_connection_status`、`android_version`、`android_screenshot`、`android_ui_state`

会动手：`android_tap`、`android_swipe`、`android_input_text`、`android_press_key`、`android_back`、`android_open_messenger`

`android_press_key` 的 `66` 是回车，在聊天界面里等于按发送。坐标用手机原始截图的坐标，不要用缩略图上量的。

## 运维速查

```bash
sudo systemctl status android-mcp-bridge
sudo journalctl -u android-mcp-bridge -f
sudo systemctl restart android-mcp-bridge
```

换 token：改 `/opt/android-mcp/.env` 里的 `ANDROID_MCP_TOKEN`，重启服务，安卓和 Aru 两端 Header 同步改。

换端口：改 `.env` 里的 `ANDROID_MCP_WS_PORT` / `ANDROID_MCP_HTTP_PORT`，网关配置的 upstream 端口同步改，然后 reload 网关 + restart 服务。

换域名：改 `.env` 里的 `ANDROID_MCP_PUBLIC_HOST`，网关的 server_name / 站点名和证书路径同步改。

## 排错

| 现象 | 看哪里 |
|---|---|
| 服务起不来 | `journalctl -u android-mcp-bridge -n 50`。最常见是 token 没填或少于 16 位 |
| 服务 active 但手机连不上 | `.env` 权限和单元文件的 `User=` 是否一致；token 有没有读成空 |
| 手机连上了，Aru 看不到工具 | Aru 侧 URL 末尾是 `/mcp`、Header 是 `Bearer <token>`、工具目录拉过、协作者范围勾了 |
| Aru 报 400 Invalid Origin / Invalid Host | 网关有没有照着 `deploy/` 里的配置写死 `Origin`、`Host` 有没有透传 |
| `A phone is already connected` | 一次只接一台手机。上一条连接没清掉就重启一次服务 |
| 截图 `1009` | `.env` 里加 `ANDROID_MCP_MAX_WS_MB=32` 再重启。不是网关 buffer 的事 |
| 输入成功但没有文字 | 安卓当前输入法要是 Mobilerun Keyboard |
| 微信弹安全验证 | 你自己手动过，过完重新截图核对 |

## 安全

- 两个内部端口只绑 `127.0.0.1`，安全组里只开 80 / 443。
- 别为了消掉报错去关认证或 Host 校验。
- token 不要进聊天记录、shell history 和仓库。`.gitignore` 已经挡了 `.env`。
- 截图和 UI 读取会碰到私人信息，发消息更是以你的名义在说话。该问你的时候会先截图给你看收件人。

## 和原 PDF 的差异

1. 多给了一份 Caddy 配置，因为这台机器的 443 大概率在 Caddy 手里。
2. 网关显式写死 `Origin`，`allowed_hosts` 加了 `:443` 和本机变体。
3. Nginx 的 `proxy_buffer_size` 从 `16m` 改成 `128k`、`proxy_buffers 8 128k`。原值每条连接要占 64MB，而且 WebSocket 那段根本不走 buffering。
4. WS 消息上限提成 `ANDROID_MCP_MAX_WS_MB`，默认 16。手机请求超时也提成了 `ANDROID_MCP_PHONE_TIMEOUT`。
5. `User=` 从 `$(whoami)` 改成写死 `root`，跟这台机器上其他服务一致，少一个 token 读成空的坑。
6. 整份部署拆成可重跑的脚本，且先有一步只读体检；`install.sh` 装完就 `py_compile` + import 检查，语法和依赖错在这一步暴露，不用等服务起不来。
