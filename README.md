# claude-token-meter

按 token 统计 Claude Code 订阅用量。多台机器、多个人用 `claude setup-token` 生成的订阅 token 时，统计**每个 token**的请求数、token 用量、等价费用和失败请求，也可以按使用人、机器、模型查看。

```
各机器 Claude Code（环境变量 CLAUDE_CODE_OAUTH_TOKEN）
   │  helper 在本地计算 token 指纹 → 只上报指纹，token 不离开本机
   ▼
OTel Collector（校验上报密钥 → 丢弃没有指纹的会话 → 指纹换成别名）
   ▼
Loki 存储 → Grafana 看板
```

- **按 token 统计**：每台机器的 Claude Code 在本地计算当前 `CLAUDE_CODE_OAUTH_TOKEN` 的 SHA-256 指纹（取前 12 位），随用量事件一起上报。同一个 token 不管在哪台机器上用，都归到同一行；机器换了 token，指纹会自动跟着变。
- **只统计 setup-token**：没有设置 `CLAUDE_CODE_OAUTH_TOKEN` 的会话（`/login` 登录的）没有指纹，Collector 直接丢弃。
- **服务器上永远看不到 token**：只有指纹和你登记的别名。提示词、回复正文、工具调用一律不入库，只保留每次 API 请求的计量事件。
- 每次 API 调用记一条，数字是逐条累加的，精确。

## 两种用法

同一套代码，区别只在客户端的上报地址填什么。

**本机自用**：服务端和客户端在同一台电脑上，只统计这台电脑的用量。

```bash
git clone https://github.com/yiju-zhao/claude-token-meter.git
cd claude-token-meter
server/init.sh
client/setup-client.sh --server http://localhost:4318 \
  --key "$(grep '^INGEST_TOKEN=' server/.env | cut -d= -f2)" --user 我
```

然后打开 http://localhost:3000 查看看板。用 Claude Code 的时候 Docker 要处于运行状态，否则那段时间的用量会丢失。

**多机部署**：服务端部署在一台所有机器都能访问的服务器上，每台客户端机器都运行一次 `setup-client.sh`，`--server` 填服务器地址。下面的步骤按这种用法来写。

## 一、部署服务端

需要一台**常开**、所有客户端都能访问到 4318 端口的机器，不一定要在公网。如果人都在一个局域网，放局域网里就行；人在各地，可以用 Tailscale / WireGuard 组网，或者用云服务器加 HTTPS。

需要 Docker：

```bash
git clone https://github.com/yiju-zhao/claude-token-meter.git
cd claude-token-meter/server
./init.sh
```

`init.sh` 会随机生成上报密钥和 Grafana 密码，写入 `server/.env`（不会提交到 git），然后启动服务，并打印看板地址、密码和上报密钥。重复运行是安全的，已有的 `.env` 不会被覆盖。

Grafana 密码只在第一次启动时生效。之后再改 `.env` 里的密码不会生效，要在 Grafana 界面里修改。

| 端口 | 用途 | 谁需要访问 |
|---|---|---|
| 4318 | 上报（OTLP HTTP） | 所有客户端机器 |
| 3000 | Grafana 看板，用户名 `admin`，密码在 `.env` 里 | 看数据的人 |

**安全**：上报密钥是明文 HTTP 传输的。如果服务器在公网，要么让所有机器走 Tailscale / WireGuard 内网，要么在前面加 HTTPS 反向代理（Caddy / Nginx），只开放 443 端口。

## 二、登记 token 别名（在服务器上）

```bash
./register-token.sh max-01          # 提示粘贴 token（不回显），本地算出指纹后登记，token 不保存
./register-token.sh max-01 --fp 83aa8dd8bbb9   # 已经知道指纹（例如在看板上看到的），直接登记
./register-token.sh --list          # 查看已登记的别名
./register-token.sh --remove max-01
```

- 不登记也能用，看板上会直接显示指纹。
- 别名只对**登记之后**上报的数据生效，登记之前的数据仍然显示指纹。所以最好在分发 token 之前先登记好。
- 也可以在自己电脑上算指纹，这样 token 不用经过服务器：`printf %s 'sk-ant-oat01-...' | shasum -a 256 | cut -c1-12`，然后用 `--fp` 登记。

## 三、配置每台客户端机器

### macOS / Linux

```bash
./client/setup-client.sh \
  --server http://监控服务器:4318 \
  --key <INGEST_TOKEN> \
  --user 张三
```

脚本会先检查服务器能不能连通、上报密钥对不对，通过后：
- 安装指纹 helper：`~/.claude/usage-monitor/token-fp.sh`
- 把上报配置写入 `~/.claude/settings.json`（原文件会自动备份）

**重启 Claude Code 后生效**。终端、VS Code、JetBrains、Agent SDK 中通过 `CLAUDE_CODE_OAUTH_TOKEN` 使用 setup-token 的会话都会被统计。

关闭上报：`./client/setup-client.sh --remove`

### Windows

还没有测试过。需要手动配置：把 `token-fp.sh` 换成同等功能的 PowerShell 脚本，再写入 `%USERPROFILE%\.claude\settings.json` 的 `otelHeadersHelper` 和 `env`，可以参照 `setup-client.sh` 里写入的内容。

### 想强制开启、不让使用人关掉

把同样的配置写进系统级的 managed settings，普通用户改不了：
- macOS：`/Library/Application Support/ClaudeCode/managed-settings.json`
- Linux：`/etc/claude-code/managed-settings.json`

## 四、看板

打开 `http://监控服务器:3000`，首页就是看板。顶部可以按 **Token**、**使用人** 筛选，右上角选时间范围。

- **总览**：请求数、总 token、输出 token、等价 API 费用、失败请求、活跃 token 数、活跃人数
- **按 Token**：各 token 的用量明细、额度窗口参考（近 5 小时 / 近 7 天）、失败请求明细（429 通常表示额度用完了，401 表示 token 失效）
- **按使用人 / 机器**：谁、在哪台机器、用的哪个 token
- **按模型**

## 注意事项

- **只统计配置了上报的机器**。同一个 token 在没配置的机器上用，或者同一个账号在 claude.ai 网页版、桌面 App 里聊天，都不会出现在看板上，但同样消耗订阅额度。
- **额度是按账号算的，不是按 token**。同一个账号生成的多个 token 共用同一份 5 小时 / 周额度。
- **等价费用**按 API 标价折算，订阅不按这个扣费，只用来比较用量大小。
- 上报失败（服务器宕机、断网）时 Claude Code 不会缓存，那段时间的数据会丢失，但不影响使用。
- 数据默认永久保留，存在 Docker 卷 `claude-token-meter_loki-data` 里。备份这个卷即可。
- 更换上报密钥：改 `.env` 里的 `INGEST_TOKEN`，执行 `docker compose up -d`，然后在各客户端重新运行 `setup-client.sh`。

## 常用命令（在 server/ 目录下）

```bash
docker compose ps                         # 状态
docker compose logs -f otel-collector     # 查看上报是否有报错
docker compose down                       # 停止（数据保留）
docker compose down -v                    # 停止并删除所有数据
```

## 目录结构

```
client/setup-client.sh        客户端一键配置（安装指纹 helper，写入 ~/.claude/settings.json）
server/init.sh                服务端首次部署
server/register-token.sh      登记 token 别名
server/docker-compose.yml     OTel Collector + Loki + Grafana
server/otel-collector.yaml    上报鉴权、只保留计量事件、指纹 → 标签
server/loki.yaml              存储配置
server/grafana/               数据源和看板（自动加载）
tools/gen_dashboard.py        看板生成器
```

修改看板：改 `tools/gen_dashboard.py`，然后运行 `python3 tools/gen_dashboard.py`，Grafana 大约 10 秒内自动加载。直接在 Grafana 界面里改的内容，会在下次重新生成时被覆盖。
