#!/usr/bin/env bash
set -euo pipefail

# ── DeskClaw Docker Compose 一键部署脚本 ──
#
# 通过 Docker Compose 从源码构建并部署 DeskClaw，包含以下服务:
#   - PostgreSQL 16
#   - Backend (FastAPI)
#   - LLM Proxy
#   - Portal (Nginx)
#
# 用法:
#   ./deploy-docker.sh           # 部署（默认）
#   ./deploy-docker.sh deploy    # 部署
#   ./deploy-docker.sh update    # 更新（拉取最新代码，重新构建并重启）
#   ./deploy-docker.sh uninstall # 卸载（停止容器，删除数据和安装目录）

INSTALL_DIR="/opt/nodeskclaw"
REPO_URL="https://github.com/NoDeskAI/nodeskclaw.git"

# ── 颜色与日志 ──

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[DeskClaw]${NC} $*"; }
ok()   { echo -e "${GREEN}[  OK  ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ WARN ]${NC} $*" >&2; }
err()  { echo -e "${RED}[ERROR ]${NC} $*" >&2; }

separator() {
  echo -e "${CYAN}────────────────────────────────────────${NC}"
}

# ── 工具函数 ──

check_root() {
  if [[ $EUID -ne 0 ]]; then
    err "请使用 root 用户运行此脚本（sudo ./deploy-docker.sh）"
    exit 1
  fi
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then
    err "无法检测操作系统，仅支持 Linux"
    exit 1
  fi
  source /etc/os-release
  if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    warn "当前系统为 $PRETTY_NAME，脚本仅测试过 Ubuntu/Debian"
  fi
}

port_in_use() {
  ss -tlnp 2>/dev/null | grep -q ":${1} " || lsof -i :"$1" &>/dev/null
}

check_ports() {
  local ports=(80 4510 4511)
  local names=("Portal" "Backend" "LLM Proxy")
  local env_vars=("PORTAL_PORT" "BACKEND_PORT" "LLM_PROXY_PORT")

  for i in "${!ports[@]}"; do
    if port_in_use "${ports[$i]}"; then
      local alt=$((ports[i] + 1))
      while port_in_use "$alt"; do
        alt=$((alt + 1))
      done
      warn "端口 ${ports[$i]}（${names[$i]}）已被占用，自动使用 ${alt}"
      echo "${env_vars[$i]}=${alt}" >> "${INSTALL_DIR}/.env"
    fi
  done
}

generate_secret() {
  openssl rand -hex 32
}

generate_encryption_key() {
  openssl rand -base64 32
}

wait_for_healthy() {
  local host="${1:-localhost}"
  local port="${2:-4510}"
  local max_attempts=90
  local attempt=1

  log "等待服务就绪..."
  while [[ $attempt -le $max_attempts ]]; do
    if curl -sf "http://${host}:${port}/api/v1/health" -o /dev/null 2>/dev/null; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  return 1
}

get_env_port() {
  local var="$1"
  local default="$2"
  local val
  val=$(grep -E "^${var}=" "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2)
  echo "${val:-$default}"
}

print_credentials() {
  local password
  password=$(docker compose -f "$INSTALL_DIR/docker-compose.yml" logs nodeskclaw-backend 2>/dev/null \
    | { grep '密码:' || true; } | tail -1 | sed 's/.*密码:[[:space:]]*//' | tr -d '[:space:]')

  local portal_port backend_port
  portal_port=$(get_env_port PORTAL_PORT 80)
  backend_port=$(get_env_port BACKEND_PORT 4510)

  separator
  ok "DeskClaw 已启动"
  echo ""
  if [[ "$portal_port" == "80" ]]; then
    echo -e "  访问地址:    ${GREEN}http://localhost${NC}"
  else
    echo -e "  访问地址:    ${GREEN}http://localhost:${portal_port}${NC}"
  fi
  echo -e "  管理员账号:  admin"
  if [[ -n "$password" ]]; then
    echo -e "  管理员密码:  ${YELLOW}${password}${NC}"
  else
    echo -e "  管理员密码:  见下方日志"
  fi
  echo ""
  log "查看管理员密码: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs nodeskclaw-backend | grep '超管初始账号' -A 3"
  log "查看服务状态:   docker compose -f ${INSTALL_DIR}/docker-compose.yml ps"
  log "查看日志:       docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f"
  separator
}

# ── 安装 Docker ──

configure_docker_mirror() {
  mkdir -p /etc/docker
  if [[ ! -f /etc/docker/daemon.json ]]; then
    cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": ["https://docker.1ms.run"]
}
EOF
    systemctl restart docker
    ok "Docker 镜像加速已配置"
  fi
}

install_docker() {
  if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    ok "Docker 已安装: $(docker --version)"
    configure_docker_mirror
    return 0
  fi

  log "安装 Docker..."

  apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  local arch
  arch=$(dpkg --print-architecture)
  local codename
  codename=$(lsb_release -cs)
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  systemctl start docker
  systemctl enable docker

  configure_docker_mirror

  ok "Docker 安装完成: $(docker --version)"
}

# ── 主流程 ──

do_deploy() {
  log "开始部署 DeskClaw（Docker Compose）..."
  check_root
  check_os

  # 1. 安装 Docker
  install_docker

  # 2. 克隆仓库
  if [[ -d "$INSTALL_DIR" ]]; then
    err "${INSTALL_DIR} 已存在"
    log "如需重新部署，请先执行: ./deploy-docker.sh uninstall"
    exit 1
  fi

  log "克隆仓库到 ${INSTALL_DIR}..."
  git clone "$REPO_URL" "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  # 3. 生成 .env
  log "生成配置文件..."
  local jwt_secret encryption_key
  jwt_secret=$(generate_secret)
  encryption_key=$(generate_encryption_key)

  cat > "${INSTALL_DIR}/.env" <<EOF
# ── DeskClaw 自动生成配置 ──
DESKCLAW_VERSION=latest
JWT_SECRET=${jwt_secret}
ENCRYPTION_KEY=${encryption_key}
EOF

  ok "配置文件已生成: ${INSTALL_DIR}/.env"

  # 4. 端口检测
  check_ports

  # 5. 从源码构建并启动
  log "构建并启动服务（首次构建需要较长时间，请耐心等待）..."
  docker compose up -d --build

  # 6. 等待就绪
  if wait_for_healthy; then
    ok "服务已就绪"
  else
    warn "服务启动超时，请检查日志: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs"
  fi

  # 7. 打印凭据
  print_credentials
}

do_update() {
  log "开始更新 DeskClaw..."
  check_root

  if [[ ! -d "$INSTALL_DIR" ]]; then
    err "${INSTALL_DIR} 不存在，请先执行部署: ./deploy-docker.sh deploy"
    exit 1
  fi

  cd "$INSTALL_DIR"

  # 1. 拉取最新代码
  log "拉取最新代码..."
  git stash --include-untracked 2>/dev/null || true
  git pull
  git stash pop 2>/dev/null || true

  # 2. 从源码重新构建并启动
  log "构建并启动服务..."
  docker compose up -d --build

  # 3. 等待就绪
  if wait_for_healthy; then
    ok "更新完成"
  else
    warn "服务启动超时，请检查日志: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs"
  fi

  print_credentials
}

do_uninstall() {
  log "卸载 DeskClaw"
  check_root

  if [[ ! -d "$INSTALL_DIR" ]]; then
    err "${INSTALL_DIR} 不存在，无需卸载"
    exit 1
  fi

  echo ""
  echo -e "${YELLOW}即将删除 DeskClaw 及所有数据（包括数据库）${NC}"
  read -r -p "确认卸载? 输入 yes 继续: " answer
  if [[ "$answer" != "yes" ]]; then
    log "已取消"
    exit 0
  fi

  cd "$INSTALL_DIR"

  # 停止并删除容器和 named volumes（pg_data 等）
  log "停止服务并清理数据..."
  docker compose down -v 2>/dev/null || true

  # 删除安装目录（源码、.env、docker-compose.yml）
  rm -rf "$INSTALL_DIR"

  ok "DeskClaw 已卸载"
  log "Docker 实例数据目录（~/.nodeskclaw/docker-instances）未删除，重新部署后会自动挂载"
  log "Docker 未被移除，如需卸载 Docker 请手动执行"
}

# ── 入口 ──

ACTION="${1:-deploy}"

case "$ACTION" in
  deploy)
    do_deploy
    ;;
  update)
    do_update
    ;;
  uninstall)
    do_uninstall
    ;;
  *)
    err "未知参数: $ACTION"
    echo ""
    echo "用法:"
    echo "  ./deploy-docker.sh           # 部署（默认）"
    echo "  ./deploy-docker.sh deploy    # 部署"
    echo "  ./deploy-docker.sh update    # 更新（拉取最新代码，重新构建并重启）"
    echo "  ./deploy-docker.sh uninstall # 卸载（停止容器，删除数据和安装目录）"
    exit 1
    ;;
esac
