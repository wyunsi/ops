#!/bin/bash
set -euo pipefail

# ─── 配置（按需修改）────────────────────────────────────────────
REGISTRY_DIR="$HOME/registry"
REGISTRY_PORT="5000"
UI_PORT="5080"
REGISTRY_TITLE="Private Registry"
# ────────────────────────────────────────────────────────────────

echo "=== 私有 Docker Registry 一键安装 ==="

# ── 1. 检查 Docker ──────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "错误：未检测到 Docker，请先安装 Docker"
    exit 1
fi
echo "✓ Docker $(docker --version | awk '{print $3}' | tr -d ',')"

# ── 2. 安装 htpasswd ────────────────────────────────────────────
if ! command -v htpasswd &>/dev/null; then
    echo "→ 安装 htpasswd..."
    if command -v apt &>/dev/null; then
        apt install -y apache2-utils
    elif command -v yum &>/dev/null; then
        yum install -y httpd-tools
    else
        echo "错误：无法自动安装 htpasswd，请手动安装 apache2-utils 或 httpd-tools"
        exit 1
    fi
fi
echo "✓ htpasswd 已就绪"

# ── 3. 创建目录 ─────────────────────────────────────────────────
mkdir -p "$REGISTRY_DIR/auth" "$REGISTRY_DIR/data"
echo "✓ 目录 $REGISTRY_DIR"

# ── 4. 收集配置 ─────────────────────────────────────────────────
echo ""
echo "─── 配置信息 ───"

# admin 密码（手动输入）
while true; do
    read -rp "  admin 密码: " -s ADMIN_PASS; echo ""
    read -rp "  确认 admin 密码: " -s ADMIN_PASS2; echo ""
    [[ "$ADMIN_PASS" == "$ADMIN_PASS2" && -n "$ADMIN_PASS" ]] && break
    echo "  密码不一致或为空，请重试"
done

# ci-bot 密码（回车随机，或手动输入）
_CIBOT_RANDOM=$(openssl rand -base64 24 | tr -d '/+=\n' | head -c 24)
read -rp "  ci-bot 密码（回车随机生成）: " -s CIBOT_PASS; echo ""
CIBOT_PASS="${CIBOT_PASS:-$_CIBOT_RANDOM}"
echo "  ci-bot 密码: $CIBOT_PASS"

# Cloudflare Tunnel token
echo ""
echo "  请前往 CF Zero Trust → Networks → Tunnels → 你的 tunnel → Configure"
echo "  复制 token（以 eyJ 开头的长字符串）"
read -rp "  CF Tunnel Token: " CF_TOKEN
if [[ -z "$CF_TOKEN" ]]; then
    echo "  ⚠ 未填写 Token，cloudflared 将跳过安装，之后可手动运行"
fi

# ── 5. 创建账号 ─────────────────────────────────────────────────
echo ""
echo "→ 创建 htpasswd 账号..."
htpasswd -Bbc "$REGISTRY_DIR/auth/htpasswd" admin "$ADMIN_PASS"
htpasswd -Bb  "$REGISTRY_DIR/auth/htpasswd" ci-bot "$CIBOT_PASS"
echo "✓ 账号已创建（admin / ci-bot）"

# 保存明文备份
cat > "$REGISTRY_DIR/.env.accounts" <<EOF
ADMIN_PASSWORD=$ADMIN_PASS
CIBOT_PASSWORD=$CIBOT_PASS
CF_TUNNEL_TOKEN=$CF_TOKEN
EOF
chmod 600 "$REGISTRY_DIR/.env.accounts"
echo "✓ 账号备份 → $REGISTRY_DIR/.env.accounts（仅 root 可读）"

# ── 6. Docker 网络 ──────────────────────────────────────────────
if ! docker network inspect registry-net &>/dev/null; then
    docker network create registry-net
    echo "✓ 网络 registry-net 已创建"
else
    echo "✓ 网络 registry-net 已存在"
fi

# ── 7. Registry 容器 ────────────────────────────────────────────
if docker inspect registry &>/dev/null; then
    docker stop registry && docker rm registry
fi

docker run -d \
    --name registry \
    --network registry-net \
    --restart unless-stopped \
    -p 127.0.0.1:${REGISTRY_PORT}:5000 \
    -e REGISTRY_AUTH=htpasswd \
    -e "REGISTRY_AUTH_HTPASSWD_REALM=${REGISTRY_TITLE}" \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
    -e REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/data \
    -e REGISTRY_STORAGE_DELETE_ENABLED=true \
    -e REGISTRY_LOG_LEVEL=info \
    -e "ACCOUNT_ADMIN=admin:${ADMIN_PASS}" \
    -e "ACCOUNT_CIBOT=ci-bot:${CIBOT_PASS}" \
    -v "$REGISTRY_DIR/auth:/auth" \
    -v "$REGISTRY_DIR/data:/data" \
    registry:2

echo "✓ Registry 已启动（127.0.0.1:${REGISTRY_PORT}）"

# ── 8. Registry UI 容器 ─────────────────────────────────────────
if docker inspect registry-ui &>/dev/null; then
    docker stop registry-ui && docker rm registry-ui
fi

docker run -d \
    --name registry-ui \
    --network registry-net \
    --restart unless-stopped \
    -p 127.0.0.1:${UI_PORT}:80 \
    -e SINGLE_REGISTRY=true \
    -e "REGISTRY_TITLE=${REGISTRY_TITLE}" \
    -e NGINX_PROXY_PASS_URL=http://registry:5000 \
    -e REGISTRY_USERNAME=admin \
    -e REGISTRY_PASSWORD="$ADMIN_PASS" \
    -e SHOW_CONTENT_DIGEST=true \
    -e DELETE_IMAGES=true \
    -e REGISTRY_SECURED=true \
    joxit/docker-registry-ui:latest

echo "✓ Registry UI 已启动（127.0.0.1:${UI_PORT}）"

# ── 9. Cloudflare Tunnel ────────────────────────────────────────
if [[ -n "$CF_TOKEN" ]]; then
    if docker inspect cloudflared &>/dev/null; then
        docker stop cloudflared && docker rm cloudflared
    fi

    docker run -d \
        --name cloudflared \
        --network host \
        --restart unless-stopped \
        cloudflare/cloudflared:latest \
        tunnel --no-autoupdate run --token "$CF_TOKEN"

    echo "✓ Cloudflare Tunnel 已启动"
    sleep 3
    if docker ps --filter "name=cloudflared" --filter "status=running" | grep -q cloudflared; then
        echo "✓ cloudflared 运行正常"
    else
        echo "⚠ cloudflared 启动异常，请检查 docker logs cloudflared"
    fi
fi

# ── 10. 验证 ────────────────────────────────────────────────────
echo ""
echo "─── 验证 ───"
sleep 2
if curl -sf -u "admin:${ADMIN_PASS}" "http://127.0.0.1:${REGISTRY_PORT}/v2/_catalog" &>/dev/null; then
    echo "✓ Registry API 正常"
else
    echo "⚠ Registry API 验证失败，请检查 docker logs registry"
fi

echo ""
echo "=== 安装完成 ==="
echo ""
echo "  Registry API : http://127.0.0.1:${REGISTRY_PORT}（对外通过 CF Tunnel）"
echo "  Registry UI  : http://127.0.0.1:${UI_PORT}（对外通过 CF Tunnel）"
echo "  账号备份      : $REGISTRY_DIR/.env.accounts"
echo ""
echo "  admin  密码 : $ADMIN_PASS"
echo "  ci-bot 密码 : $CIBOT_PASS  ← 填入 GitHub Secret: REGISTRY_PASSWORD"
echo ""
echo "  CF Tunnel 路由配置（控制台手动完成）："
echo "    registry 域名 → http://127.0.0.1:${REGISTRY_PORT}"
echo "    UI 域名       → http://127.0.0.1:${UI_PORT}"
