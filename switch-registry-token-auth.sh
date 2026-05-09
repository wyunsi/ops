#!/bin/bash
# 切换私有 Registry 到 CF Worker Token Auth 认证
#
# 用法（填好下方三个变量后运行，或直接 curl | bash）：
#   curl -fsSL https://raw.githubusercontent.com/wyunsi/ops/main/switch-registry-token-auth.sh | bash
#
# 前置条件：
#   - 已按 setup-registry.sh 安装好 registry 容器
#   - 已完成本地 npm run setup + npm run deploy（CF Worker 已上线）

set -euo pipefail

# ── 填这三个变量 ────────────────────────────────────────────────────
CF_WORKER_DOMAIN="license.touks.eu.org"   # CF Worker 的域名
REGISTRY_DOMAIN="registry.touks.eu.org"  # Registry 对外域名
ISSUER="wyunsi-auth"                      # 和 CF Worker secret REGISTRY_ISSUER 一致
# ───────────────────────────────────────────────────────────────────

REGISTRY_DIR="$HOME/registry"
CERT_FILE="$REGISTRY_DIR/certs/auth-public.crt"
CONFIG_FILE="$REGISTRY_DIR/registry-config.yml"

echo "=== 切换 Registry 到 Token Auth ==="
echo "  CF Worker : https://$CF_WORKER_DOMAIN"
echo "  Registry  : $REGISTRY_DOMAIN"
echo "  Issuer    : $ISSUER"
echo

mkdir -p "$REGISTRY_DIR/certs"

# 1. 从 CF Worker 自动拉取公钥证书
echo "→ 从 CF Worker 拉取公钥证书..."
HTTP_CODE=$(curl -s -o "$CERT_FILE" -w "%{http_code}" \
    "https://${CF_WORKER_DOMAIN}/v1/registry/public-key")

if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ 证书已下载：$CERT_FILE"
elif [ -f "$CERT_FILE" ] && grep -q "BEGIN CERTIFICATE" "$CERT_FILE"; then
    echo "✓ 使用已有证书：$CERT_FILE"
else
    echo "✖ 无法从 CF Worker 下载证书（HTTP $HTTP_CODE）"
    echo "  请确认："
    echo "    1. CF Worker 已部署：npm run deploy"
    echo "    2. 域名 $CF_WORKER_DOMAIN 已解析到 CF Worker"
    echo "    3. 本地 npm run setup 已成功运行"
    exit 1
fi

# 2. 写 registry-config.yml
echo "→ 写入 Registry 配置..."
cat > "$CONFIG_FILE" << CONF
version: 0.1
log:
  level: warn
storage:
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true
http:
  addr: :5000
auth:
  token:
    realm: https://${CF_WORKER_DOMAIN}/v1/registry/token
    service: ${REGISTRY_DOMAIN}
    issuer: ${ISSUER}
    rootcertbundle: /certs/auth-public.crt
CONF
echo "✓ 配置已写入：$CONFIG_FILE"

# 3. 停止旧 registry 容器
if docker inspect registry &>/dev/null 2>&1; then
    echo "→ 停止旧 registry 容器..."
    docker stop registry && docker rm registry
fi

# 4. 启动新 registry（挂载配置和证书）
echo "→ 启动 registry (Token Auth)..."
docker run -d \
    --name registry \
    --network registry-net \
    --restart always \
    -v registry-data:/var/lib/registry \
    -v "$CONFIG_FILE":/etc/docker/registry/config.yml:ro \
    -v "$CERT_FILE":/certs/auth-public.crt:ro \
    registry:2

sleep 2

# 5. 验证
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5000/v2/)
if [ "$HTTP_CODE" = "401" ]; then
    echo "✓ Registry 返回 401（Token Auth 已生效）"
    echo
    echo "=== 完成 ==="
    echo "  客户登录命令："
    echo "  docker login $REGISTRY_DOMAIN -u license -p <LICENSE_KEY>"
else
    echo "✖ Registry 响应异常（HTTP $HTTP_CODE），查看日志："
    echo "  docker logs registry"
    exit 1
fi
