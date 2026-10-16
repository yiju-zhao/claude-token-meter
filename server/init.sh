#!/usr/bin/env bash
# 首次部署：生成密钥和别名配置，然后启动服务。重复运行是安全的（已有的 .env 不会被覆盖）
set -euo pipefail
cd "$(dirname "$0")"
command -v docker >/dev/null || { echo "需要先安装 Docker" >&2; exit 1; }

if [[ ! -f .env ]]; then
  (
    umask 077
    cat > .env <<ENV
# 客户端上报用的密钥（所有机器共用，泄露后改掉并执行 docker compose up -d）
INGEST_TOKEN=$(openssl rand -hex 24)
# Grafana 管理员密码（用户名 admin），只在 Grafana 第一次启动时生效
GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=')
ENV
  )
  echo "已生成 .env"
fi

./register-token.sh --apply
docker compose up -d

set -a; source .env; set +a
cat <<INFO

启动完成
  看板:      http://<本机地址>:3000   用户名 admin   密码 ${GRAFANA_ADMIN_PASSWORD}
  上报地址:  http://<本机地址>:4318
  上报密钥:  ${INGEST_TOKEN}

下一步：
  1. 登记 token 别名：./register-token.sh max-01
  2. 在每台客户端运行：client/setup-client.sh --server http://<本机地址>:4318 --key ${INGEST_TOKEN} --user <名字>
INFO
