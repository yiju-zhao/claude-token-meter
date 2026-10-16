#!/usr/bin/env bash
# 登记 setup-token 的别名。服务器上只保存指纹（sha256 前 12 位），不保存 token。
#
#   ./register-token.sh max-01              # 提示粘贴 token（不回显），本地算指纹后登记为 max-01
#   ./register-token.sh max-01 --fp 83aa8dd8bbb9   # 已知指纹（例如看板上看到的），直接登记
#   ./register-token.sh --list              # 查看已登记的别名
#   ./register-token.sh --remove max-01     # 删除别名
#
# 别名只对登记之后上报的数据生效；登记之前的数据在看板上显示为指纹。
set -euo pipefail
cd "$(dirname "$0")"
ALIASES=token-aliases.txt
OUT=token-aliases.yaml

if [[ ! -f "$ALIASES" ]]; then
  printf '%s\n' "# setup-token 指纹 → 别名。用 ./register-token.sh 维护，不要写入 token 本身" "# 指纹(12位)    别名" > "$ALIASES"
fi

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

generate() {
  {
    echo "# 由 register-token.sh 根据 token-aliases.txt 生成，不要手动修改"
    echo "processors:"
    echo "  transform/token_alias:"
    echo "    error_mode: ignore"
    echo "    log_statements:"
    echo "      - context: resource"
    echo "        statements:"
    { grep -vE '^\s*(#|$)' "$ALIASES" || true; } | while read -r fp name; do
      echo "          - set(attributes[\"token\"], \"$name\") where attributes[\"token.fp\"] == \"$fp\""
    done
    echo "          - set(attributes[\"token\"], attributes[\"token.fp\"]) where attributes[\"token\"] == nil"
  } > "$OUT"
}

apply() {
  generate
  if docker compose ps --status running --services 2>/dev/null | grep -qx otel-collector; then
    docker compose restart otel-collector >/dev/null 2>&1
    echo "已生效（Collector 已重启）"
  fi
}

case "${1:-}" in
  ""|-h|--help) sed -n '2,10p' "$0"; exit 0 ;;
  --list) grep -vE '^\s*(#|$)' "$ALIASES" || echo "（还没有登记）"; exit 0 ;;
  --apply) apply; exit 0 ;;
  --remove)
    name="${2:?缺少别名}"
    grep -vE "^[0-9a-f]{12}[[:space:]]+${name}\$" "$ALIASES" > "$ALIASES.tmp"; mv "$ALIASES.tmp" "$ALIASES"
    echo "已删除 $name"; apply; exit 0 ;;
esac

name="$1"
if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "别名只能包含字母、数字、点、下划线、横线" >&2; exit 1
fi

if [[ "${2:-}" == "--fp" ]]; then
  fp="${3:?缺少指纹}"
else
  read -r -s -p "粘贴 ${name} 对应的 setup-token（不会显示，也不会保存）: " token; echo
  [[ "$token" == sk-ant-* ]] || { echo "看起来不是 Claude token（应以 sk-ant- 开头）" >&2; exit 1; }
  fp=$(printf %s "$token" | sha256 | cut -c1-12)
  unset token
fi
[[ "$fp" =~ ^[0-9a-f]{12}$ ]] || { echo "指纹格式不对，应为 12 位十六进制" >&2; exit 1; }

# 同一个指纹或同一个别名只保留一条
grep -vE "^${fp}[[:space:]]|[[:space:]]${name}\$" "$ALIASES" > "$ALIASES.tmp" || true
mv "$ALIASES.tmp" "$ALIASES"
printf '%s  %s\n' "$fp" "$name" >> "$ALIASES"
echo "已登记：$fp → $name"
apply
