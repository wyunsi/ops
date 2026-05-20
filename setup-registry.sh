#!/bin/bash
# 私有 Docker Registry 一键安装（Cloudflare Tunnel + Token Auth）
#
# 前置条件：
#   1. CF Worker 已部署（npm run setup && npm run deploy）
#   2. CF Tunnel 已在 CF Zero Trust Dashboard 创建，路由配置：
#        registry 域名 → http://localhost:5000
#        UI 域名       → http://localhost:5080
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/wyunsi/ops/main/setup-registry.sh | bash

set -euo pipefail

# ── 修改这三个变量 ───────────────────────────────────────────────────────────
CF_WORKER_DOMAIN="license.touks.eu.org"
REGISTRY_DOMAIN="registry.touks.eu.org"
ISSUER="wyunsi-auth"
# ─────────────────────────────────────────────────────────────────────────────

REGISTRY_DIR="$HOME/registry"
CERT_FILE="$REGISTRY_DIR/certs/auth-public.crt"
CONFIG_FILE="$REGISTRY_DIR/registry-config.yml"

echo "=== 私有 Docker Registry 一键安装 ==="
echo "  CF Worker : https://$CF_WORKER_DOMAIN"
echo "  Registry  : $REGISTRY_DOMAIN"
echo ""

# ── 1. 检查 Docker ───────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "✖ 未检测到 Docker，请先安装"
    exit 1
fi
echo "✓ Docker $(docker --version | awk '{print $3}' | tr -d ',')"

# ── 2. 收集 CF Tunnel Token ──────────────────────────────────────────────────
echo ""
echo "请前往 CF Zero Trust → Networks → Tunnels → 你的 tunnel → Configure"
echo "复制 token（以 eyJ 开头的长字符串）"
read -rp "CF Tunnel Token（回车跳过）: " CF_TOKEN </dev/tty
echo ""

# ── 3. 从 CF Worker 拉取公钥证书 ─────────────────────────────────────────────
mkdir -p "$REGISTRY_DIR/certs"
echo "→ 拉取公钥证书..."
HTTP_CODE=$(curl -s -o "$CERT_FILE" -w "%{http_code}" \
    "https://${CF_WORKER_DOMAIN}/v1/registry/public-key")

if [ "$HTTP_CODE" = "200" ] && grep -q "BEGIN CERTIFICATE" "$CERT_FILE" 2>/dev/null; then
    echo "✓ 证书已下载：$CERT_FILE"
elif [ -f "$CERT_FILE" ] && grep -q "BEGIN CERTIFICATE" "$CERT_FILE" 2>/dev/null; then
    echo "✓ 使用已有证书：$CERT_FILE"
else
    echo "✖ 无法从 CF Worker 下载证书（HTTP $HTTP_CODE）"
    echo "  请确认 CF Worker 已部署且 $CF_WORKER_DOMAIN 已解析"
    exit 1
fi

# ── 4. 写 registry-config.yml ────────────────────────────────────────────────
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
echo "✓ 配置已写入"

# ── 5. Docker 网络 ───────────────────────────────────────────────────────────
if ! docker network inspect registry-net &>/dev/null; then
    docker network create registry-net
    echo "✓ 网络 registry-net 已创建"
fi

# ── 6. Registry 容器 ─────────────────────────────────────────────────────────
if docker inspect registry &>/dev/null; then
    docker stop registry && docker rm registry
fi

docker run -d \
    --name registry \
    --network registry-net \
    --restart always \
    -p 127.0.0.1:5000:5000 \
    -v registry-data:/var/lib/registry \
    -v "$CONFIG_FILE":/etc/docker/registry/config.yml:ro \
    -v "$CERT_FILE":/certs/auth-public.crt:ro \
    registry:2

echo "✓ Registry 已启动（127.0.0.1:5000）"

# ── 7. Registry UI 容器 ──────────────────────────────────────────────────────
if docker inspect registry-ui &>/dev/null; then
    docker stop registry-ui && docker rm registry-ui
fi

docker run -d \
    --name registry-ui \
    --network registry-net \
    --restart always \
    -p 127.0.0.1:5080:80 \
    -e SINGLE_REGISTRY=true \
    -e REGISTRY_TITLE="Private Registry" \
    -e NGINX_PROXY_PASS_URL=http://registry:5000 \
    -e SHOW_CONTENT_DIGEST=true \
    -e DELETE_IMAGES=true \
    -e REGISTRY_SECURED=true \
    joxit/docker-registry-ui:latest

echo "✓ Registry UI 已启动（127.0.0.1:5080）"

# ── 8. Cloudflare Tunnel ─────────────────────────────────────────────────────
if [[ -n "$CF_TOKEN" ]]; then
    if docker inspect cloudflared &>/dev/null; then
        docker stop cloudflared && docker rm cloudflared
    fi

    docker run -d \
        --name cloudflared \
        --network host \
        --restart always \
        cloudflare/cloudflared:latest \
        tunnel --no-autoupdate run --token "$CF_TOKEN"

    sleep 3
    if docker ps --filter "name=cloudflared" --filter "status=running" | grep -q cloudflared; then
        echo "✓ Cloudflare Tunnel 已启动"
    else
        echo "⚠ cloudflared 启动异常，请检查：docker logs cloudflared"
    fi
fi

# ── 9. 验证 ──────────────────────────────────────────────────────────────────
sleep 2
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5000/v2/)
if [ "$HTTP_CODE" = "401" ]; then
    echo "✓ Registry 返回 401（Token Auth 已生效）"
else
    echo "✖ Registry 响应异常（HTTP $HTTP_CODE）：docker logs registry"
    exit 1
fi

echo ""
echo "=== 安装完成 ==="
echo ""
echo "  CF Tunnel 路由（请在 CF Dashboard 确认）："
echo "    $REGISTRY_DOMAIN → http://localhost:5000"
echo ""
echo "  客户登录命令："
echo "    docker login $REGISTRY_DOMAIN -u license -p <LICENSE_KEY>"
