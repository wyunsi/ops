#!/bin/bash
# 切换私有 Registry 到 CF Worker Token Auth 认证
# 用法：bash switch-registry-token-auth.sh
#
# 运行前需要：
#   1. 已按 setup-registry.sh 安装好 registry 容器
#   2. 已把 public.crt 上传到 ~/registry/certs/auth-public.crt
#
# 填写下方三个变量后运行即可

set -euo pipefail

# ── 填这三个变量 ────────────────────────────────────────────────────
CF_WORKER_DOMAIN="license.touks.eu.org"   # CF Worker 的域名（解析到 Worker 的域名）
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

# 1. 检查证书
if [ ! -f "$CERT_FILE" ]; then
    echo "✖ 证书不存在：$CERT_FILE"
    echo "  请先将 public.crt 上传到该路径后重试"
    exit 1
fi
echo "✓ 证书已就绪：$CERT_FILE"

# 2. 写 registry-config.yml
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
echo "✓ 配置文件已写入：$CONFIG_FILE"

# 3. 停止并删除旧 registry 容器
if docker inspect registry &>/dev/null; then
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

echo

# 5. 验证
sleep 2
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5000/v2/)
if [ "$HTTP_CODE" = "401" ]; then
    echo "✓ Registry 返回 401（Token Auth 生效）"
    echo
    echo "=== 完成 ==="
    echo "  Registry 已切换到 Token Auth"
    echo "  docker login $REGISTRY_DOMAIN -u license -p <LICENSE_KEY>"
else
    echo "✖ Registry 响应异常（HTTP $HTTP_CODE），检查日志："
    echo "  docker logs registry"
    exit 1
fi
