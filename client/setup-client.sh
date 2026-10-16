#!/usr/bin/env bash
# 给本机的 Claude Code 开启 setup-token 用量上报
#
# 用法：
#   ./setup-client.sh --server http://监控服务器:4318 --key 上报密钥 --user 张三 [--host 机器名]
#   ./setup-client.sh --remove        # 关闭上报，删除本脚本写入的配置
#
# 参数：
#   --server    Collector 地址（OTLP HTTP，默认端口 4318）
#   --key       服务端 .env 里的 INGEST_TOKEN（监控服务器的上报密钥，不是 Claude 的 token）
#   --user      使用人名字，看板里按这个区分人
#   --host      可选。机器名，默认取 hostname
#   --settings  可选。settings.json 路径，默认 ~/.claude/settings.json
#
# 只有通过环境变量 CLAUDE_CODE_OAUTH_TOKEN 使用 setup-token 的会话会被统计。
# token 本身不会离开本机：helper 只上报它的 sha256 指纹（前 12 位）。
set -euo pipefail

SERVER="" KEY="" USER_NAME="" HOST_NAME="$(hostname -s 2>/dev/null || hostname)"
SETTINGS="${HOME}/.claude/settings.json" REMOVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --user) USER_NAME="$2"; shift 2 ;;
    --host) HOST_NAME="$2"; shift 2 ;;
    --settings) SETTINGS="$2"; shift 2 ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [[ $REMOVE -eq 0 && ( -z "$SERVER" || -z "$KEY" || -z "$USER_NAME" ) ]]; then
  echo "缺少参数：--server、--key、--user 必填（--help 查看用法）" >&2
  exit 1
fi
command -v python3 >/dev/null || { echo "需要 python3" >&2; exit 1; }

HELPER_DIR="$(dirname "$SETTINGS")/usage-monitor"
HELPER="${HELPER_DIR}/token-fp.sh"

if [[ $REMOVE -eq 0 ]]; then
  # 先检查服务器和密钥，通过了再写配置
  code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 -X POST "${SERVER%/}/v1/logs" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d '{"resourceLogs":[]}' || true)
  case "$code" in
    200) echo "连通性检查：OK" ;;
    401) echo "连通性检查：服务器可达，但上报密钥不对（401），未修改任何配置" >&2; exit 1 ;;
    *)   echo "连通性检查：连不上 ${SERVER}（HTTP ${code}），请检查地址、端口和防火墙，未修改任何配置" >&2; exit 1 ;;
  esac

  # Claude Code 上报前会运行这个 helper，把它输出的 JSON 加到上报请求头里
  mkdir -p "$HELPER_DIR"
  cat > "$HELPER" <<'SH'
#!/bin/sh
# 由 setup-client.sh 安装。输出当前 setup-token 的指纹（sha256 前 12 位），不输出 token 本身
if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  echo '{}'
  exit 0
fi
if command -v sha256sum >/dev/null 2>&1; then
  fp=$(printf %s "$CLAUDE_CODE_OAUTH_TOKEN" | sha256sum | cut -c1-12)
else
  fp=$(printf %s "$CLAUDE_CODE_OAUTH_TOKEN" | shasum -a 256 | cut -c1-12)
fi
printf '{"x-claude-token-fp":"%s"}\n' "$fp"
SH
  chmod 755 "$HELPER"
fi

mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] && cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"

python3 - "$SETTINGS" "$REMOVE" "$SERVER" "$KEY" "$USER_NAME" "$HOST_NAME" "$HELPER" <<'PY'
import json, os, sys
from urllib.parse import quote

path, remove, server, key, user, host, helper = sys.argv[1:8]
keys = [
    "CLAUDE_CODE_ENABLE_TELEMETRY", "OTEL_LOGS_EXPORTER", "OTEL_EXPORTER_OTLP_PROTOCOL",
    "OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_HEADERS", "OTEL_RESOURCE_ATTRIBUTES",
]

data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        data = json.load(f)
env = data.setdefault("env", {})

if remove == "1":
    for k in keys:
        env.pop(k, None)
    if not env:
        data.pop("env")
    if data.get("otelHeadersHelper") == helper:
        data.pop("otelHeadersHelper")
else:
    # OTEL_RESOURCE_ATTRIBUTES 的值需要百分号编码（中文名、空格、逗号等）
    attrs = {"user.name": user, "host.name": host}
    env.update({
        "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
        "OTEL_LOGS_EXPORTER": "otlp",
        "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
        "OTEL_EXPORTER_OTLP_ENDPOINT": server.rstrip("/"),
        "OTEL_EXPORTER_OTLP_HEADERS": f"Authorization=Bearer {key}",
        "OTEL_RESOURCE_ATTRIBUTES": ",".join(f"{k}={quote(v, safe='')}" for k, v in attrs.items()),
    })
    data["otelHeadersHelper"] = helper

tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY

if [[ $REMOVE -eq 1 ]]; then
  rm -f "$HELPER"; rmdir "$HELPER_DIR" 2>/dev/null || true
  echo "已关闭用量上报（${SETTINGS}）。重启 Claude Code 生效。"
  exit 0
fi

echo "已写入 ${SETTINGS}，helper 安装在 ${HELPER}"
echo "重启 Claude Code 后生效。只有设置了 CLAUDE_CODE_OAUTH_TOKEN 的会话会被统计。"
