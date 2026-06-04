#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2026.06.05"

usage() {
  cat <<'EOF'
OpenVPN 落地机一键配置脚本

用法:
  bash openvpn-landing-setup.sh
  bash openvpn-landing-setup.sh --render-only /tmp/openvpn-render

说明:
  - 自动部署 yyxx/openvpn，并使用镜像自带 Web UI 做可视化管理。
  - 默认使用 OpenVPN TCP，适合 IEPL/nyanpass 的 TCP 端口转发。
  - 脚本不会设置或保存 Web 管理员账号密码；部署完成后请在 Web 面板手动修改。
  - --render-only 只生成 docker-compose.yml、data/config.json、deploy.env，不启动 Docker。

--render-only 可用环境变量:
  OVPN_INSTALL_DIR
  OVPN_CONTAINER_NAME
  OVPN_IMAGE
  OVPN_WEB_PORT
  OVPN_PORT
  OVPN_SERVER_NAME
  OVPN_SERVER_CN
  OVPN_SERVER_HOST
  OVPN_ENABLE_IPV6
  OVPN_ENABLE_GATEWAY
  OVPN_ENABLE_AUTH
  OVPN_AUTO_INSTALL_DOCKER
  OVPN_AUTO_INSTALL_COMPOSE
  OVPN_PULL_OPENVPN_UI
  OVPN_LANDING_IPV4
  OVPN_CREATE_CLIENT
  OVPN_CLIENT_NAME
  OVPN_USE_RELAY
  OVPN_RELAY_HOST
  OVPN_RELAY_PORT
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

is_true() {
  case "${1,,}" in
    y|yes|true|1|on) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_bool() {
  if is_true "$1"; then
    printf 'true'
  else
    printf 'false'
  fi
}

prompt_text() {
  local prompt="$1"
  local default_value="$2"
  local value

  read -r -p "$prompt [$default_value]: " value
  printf '%s' "${value:-$default_value}"
}

prompt_bool() {
  local prompt="$1"
  local default_value="$2"
  local value
  local hint

  if is_true "$default_value"; then
    hint="Y/n"
  else
    hint="y/N"
  fi

  read -r -p "$prompt [$hint]: " value
  value="${value:-$default_value}"
  normalize_bool "$value"
}

validate_port() {
  local name="$1"
  local port="$2"

  [[ "$port" =~ ^[0-9]+$ ]] || die "$name 必须是数字端口。"
  (( port >= 1 && port <= 65535 )) || die "$name 必须在 1-65535 之间。"
}

validate_name() {
  local name="$1"
  local value="$2"

  [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] || die "$name 只允许字母、数字、点、下划线和短横线。"
}

validate_host() {
  local host="$1"

  [[ "$host" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "服务器地址只允许域名、IP、点、冒号和短横线。"
}

detect_public_ipv4() {
  local ip

  ip="$(ip -4 route get 8.8.8.8 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  printf '%s' "${ip:-127.0.0.1}"
}

random_suffix() {
  if command -v od >/dev/null 2>&1; then
    od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
  else
    date +%s%N
  fi
}

collect_from_env() {
  OVPN_INSTALL_DIR="${OVPN_INSTALL_DIR:-/opt/yyxx-openvpn}"
  OVPN_CONTAINER_NAME="${OVPN_CONTAINER_NAME:-openvpn}"
  OVPN_IMAGE="${OVPN_IMAGE:-yyxx/openvpn:v2.5.1}"
  OVPN_WEB_PORT="${OVPN_WEB_PORT:-8833}"
  OVPN_PORT="${OVPN_PORT:-443}"
  OVPN_SERVER_NAME="${OVPN_SERVER_NAME:-server_$(random_suffix)}"
  OVPN_SERVER_CN="${OVPN_SERVER_CN:-ovpn_$(random_suffix)}"
  OVPN_SERVER_HOST="${OVPN_SERVER_HOST:-127.0.0.1}"
  OVPN_ENABLE_IPV6="$(normalize_bool "${OVPN_ENABLE_IPV6:-false}")"
  OVPN_ENABLE_GATEWAY="$(normalize_bool "${OVPN_ENABLE_GATEWAY:-true}")"
  OVPN_ENABLE_AUTH="$(normalize_bool "${OVPN_ENABLE_AUTH:-true}")"
  OVPN_AUTO_INSTALL_DOCKER="$(normalize_bool "${OVPN_AUTO_INSTALL_DOCKER:-true}")"
  OVPN_AUTO_INSTALL_COMPOSE="$(normalize_bool "${OVPN_AUTO_INSTALL_COMPOSE:-true}")"
  OVPN_PULL_OPENVPN_UI="$(normalize_bool "${OVPN_PULL_OPENVPN_UI:-true}")"
  OVPN_LANDING_IPV4="${OVPN_LANDING_IPV4:-$OVPN_SERVER_HOST}"
  OVPN_CREATE_CLIENT="$(normalize_bool "${OVPN_CREATE_CLIENT:-true}")"
  OVPN_CLIENT_NAME="${OVPN_CLIENT_NAME:-client1}"
  OVPN_USE_RELAY="$(normalize_bool "${OVPN_USE_RELAY:-false}")"
  OVPN_RELAY_HOST="${OVPN_RELAY_HOST:-}"
  OVPN_RELAY_PORT="${OVPN_RELAY_PORT:-$OVPN_PORT}"
}

collect_interactive() {
  local detected_ip
  detected_ip="$(detect_public_ipv4)"

  printf '\nOpenVPN 落地机一键配置脚本 v%s\n\n' "$VERSION"
  OVPN_INSTALL_DIR="$(prompt_text "安装目录" "/opt/yyxx-openvpn")"
  OVPN_CONTAINER_NAME="$(prompt_text "容器名称" "openvpn")"
  OVPN_IMAGE="$(prompt_text "Docker 镜像" "yyxx/openvpn:v2.5.1")"
  OVPN_SERVER_NAME="server_$(random_suffix)"
  OVPN_SERVER_CN="ovpn_$(random_suffix)"
  OVPN_SERVER_HOST="$(prompt_text "客户端配置使用的落地机 IP/域名" "$detected_ip")"
  OVPN_LANDING_IPV4="$(prompt_text "落地机 IPv4" "$detected_ip")"
  OVPN_WEB_PORT="$(prompt_text "Web 面板对外端口" "8833")"
  OVPN_PORT="$(prompt_text "OpenVPN TCP 对外端口" "443")"
  OVPN_ENABLE_IPV6="$(prompt_bool "是否启用 OpenVPN IPv6" "false")"
  OVPN_ENABLE_GATEWAY="$(prompt_bool "是否让客户端默认全局走 VPN 出口" "true")"
  OVPN_ENABLE_AUTH="$(prompt_bool "是否启用 VPN 账号密码验证" "true")"
  OVPN_AUTO_INSTALL_DOCKER="$(prompt_bool "缺少 Docker 时是否自动安装" "true")"
  OVPN_AUTO_INSTALL_COMPOSE="$(prompt_bool "缺少 Docker Compose 时是否自动安装" "true")"
  OVPN_PULL_OPENVPN_UI="$(prompt_bool "启动前是否自动下载 OpenVPN-UI 镜像" "true")"
  OVPN_CREATE_CLIENT="$(prompt_bool "是否自动创建初始客户端配置" "true")"

  if [[ "$OVPN_CREATE_CLIENT" == "true" ]]; then
    OVPN_CLIENT_NAME="$(prompt_text "初始客户端名称" "client1")"
    OVPN_USE_RELAY="$(prompt_bool "是否使用中转入口生成这个客户端配置" "false")"

    if [[ "$OVPN_USE_RELAY" == "true" ]]; then
      OVPN_RELAY_HOST="$(prompt_text "中转入口 IP/域名" "$OVPN_SERVER_HOST")"
      OVPN_RELAY_PORT="$(prompt_text "中转入口端口" "$OVPN_PORT")"
    else
      OVPN_RELAY_HOST=""
      OVPN_RELAY_PORT="$OVPN_PORT"
    fi
  else
    OVPN_CLIENT_NAME="client1"
    OVPN_USE_RELAY="false"
    OVPN_RELAY_HOST=""
    OVPN_RELAY_PORT="$OVPN_PORT"
  fi
}

validate_config() {
  [[ -n "$OVPN_INSTALL_DIR" ]] || die "安装目录不能为空。"
  [[ -n "$OVPN_IMAGE" ]] || die "Docker 镜像不能为空。"
  [[ "$OVPN_IMAGE" != *".."* && "$OVPN_IMAGE" != *[[:space:]]* ]] || die "Docker 镜像名称不合法。"

  validate_port "Web 面板端口" "$OVPN_WEB_PORT"
  validate_port "OpenVPN 端口" "$OVPN_PORT"
  validate_name "容器名称" "$OVPN_CONTAINER_NAME"
  validate_name "OpenVPN 服务器证书名称" "$OVPN_SERVER_NAME"
  validate_name "OpenVPN CA 通用名" "$OVPN_SERVER_CN"
  validate_host "$OVPN_SERVER_HOST"
  validate_host "$OVPN_LANDING_IPV4"

  if [[ "$OVPN_WEB_PORT" == "$OVPN_PORT" ]]; then
    die "Web 面板端口和 OpenVPN 端口不能相同。"
  fi

  if [[ "$OVPN_CREATE_CLIENT" == "true" ]]; then
    validate_name "初始客户端名称" "$OVPN_CLIENT_NAME"

    if [[ "$OVPN_USE_RELAY" == "true" ]]; then
      [[ -n "$OVPN_RELAY_HOST" ]] || die "中转入口 IP/域名不能为空。"
      validate_host "$OVPN_RELAY_HOST"
      validate_port "中转入口端口" "$OVPN_RELAY_PORT"
      OVPN_CLIENT_REMOTE_HOST="$OVPN_RELAY_HOST"
      OVPN_CLIENT_REMOTE_PORT="$OVPN_RELAY_PORT"
    else
      OVPN_CLIENT_REMOTE_HOST="$OVPN_LANDING_IPV4"
      OVPN_CLIENT_REMOTE_PORT="$OVPN_PORT"
    fi
  else
    OVPN_CLIENT_REMOTE_HOST=""
    OVPN_CLIENT_REMOTE_PORT=""
  fi
}

render_compose() {
  local compose_file="$OVPN_INSTALL_DIR/docker-compose.yml"

  cat >"$compose_file" <<EOF
services:
  openvpn:
    image: $OVPN_IMAGE
    container_name: $OVPN_CONTAINER_NAME
    cap_add:
      - NET_ADMIN
    ports:
      - "$OVPN_WEB_PORT:8833/tcp"
      - "$OVPN_PORT:$OVPN_PORT/tcp"
    volumes:
      - ./data:/data
      - /etc/localtime:/etc/localtime:ro
    restart: unless-stopped
EOF

  if [[ "$OVPN_ENABLE_IPV6" == "true" ]]; then
    cat >>"$compose_file" <<'EOF'
    sysctls:
      - net.ipv6.conf.default.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1

networks:
  default:
    enable_ipv6: true
EOF
  fi
}

render_config_json() {
  local config_file="$OVPN_INSTALL_DIR/data/config.json"

  cat >"$config_file" <<EOF
{
  "system": {
    "base": {
      "site_url": "http://$OVPN_SERVER_HOST:$OVPN_WEB_PORT",
      "web_port": "8833",
      "server_cn": "$OVPN_SERVER_CN",
      "server_name": "$OVPN_SERVER_NAME",
      "auto_update_ovpn_config": true,
      "history_max_days": 90,
      "validate_client_config": false
    }
  },
  "openvpn": {
    "ovpn_port": $OVPN_PORT,
    "ovpn_proto": "tcp-server",
    "ovpn_subnet": "10.8.0.0/24",
    "ovpn_max_clients": 200,
    "ovpn_gateway": $OVPN_ENABLE_GATEWAY,
    "ovpn_management": "127.0.0.1:7505",
    "ovpn_ipv6": $OVPN_ENABLE_IPV6,
    "ovpn_subnet6": "fdaf:f178:e916:6dd0::/64",
    "ovpn_push_dns1": "8.8.8.8",
    "ovpn_push_dns2": "2001:4860:4860::8888"
  }
}
EOF
}

render_env_summary() {
  local env_file="$OVPN_INSTALL_DIR/deploy.env"

  cat >"$env_file" <<EOF
OVPN_CONTAINER_NAME=$OVPN_CONTAINER_NAME
OVPN_IMAGE=$OVPN_IMAGE
OVPN_WEB_PORT=$OVPN_WEB_PORT
OVPN_PORT=$OVPN_PORT
OVPN_SERVER_NAME=$OVPN_SERVER_NAME
OVPN_SERVER_CN=$OVPN_SERVER_CN
OVPN_SERVER_HOST=$OVPN_SERVER_HOST
OVPN_ENABLE_IPV6=$OVPN_ENABLE_IPV6
OVPN_ENABLE_GATEWAY=$OVPN_ENABLE_GATEWAY
OVPN_ENABLE_AUTH=$OVPN_ENABLE_AUTH
OVPN_AUTO_INSTALL_DOCKER=$OVPN_AUTO_INSTALL_DOCKER
OVPN_AUTO_INSTALL_COMPOSE=$OVPN_AUTO_INSTALL_COMPOSE
OVPN_PULL_OPENVPN_UI=$OVPN_PULL_OPENVPN_UI
OVPN_LANDING_IPV4=$OVPN_LANDING_IPV4
OVPN_CREATE_CLIENT=$OVPN_CREATE_CLIENT
OVPN_CLIENT_NAME=$OVPN_CLIENT_NAME
OVPN_USE_RELAY=$OVPN_USE_RELAY
OVPN_RELAY_HOST=$OVPN_RELAY_HOST
OVPN_RELAY_PORT=$OVPN_RELAY_PORT
OVPN_CLIENT_REMOTE_HOST=$OVPN_CLIENT_REMOTE_HOST
OVPN_CLIENT_REMOTE_PORT=$OVPN_CLIENT_REMOTE_PORT
EOF
  chmod 600 "$env_file"
}

render_files() {
  mkdir -p "$OVPN_INSTALL_DIR/data"
  render_compose
  render_config_json
  render_env_summary
}

directory_has_entries() {
  local dir="$1"

  [[ -d "$dir" ]] || return 1
  find "$dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .
}

ensure_clean_data_dir() {
  local data_dir="$OVPN_INSTALL_DIR/data"
  local backup_example

  if [[ -f "$data_dir/server.conf" ]]; then
    die "检测到已有 $data_dir/server.conf。为避免覆盖证书和客户端配置，脚本已停止。"
  fi

  if directory_has_entries "$data_dir"; then
    backup_example="$OVPN_INSTALL_DIR.bak.\$(date +%F-%H%M%S)"
    die "检测到未完成的旧数据目录 $data_dir，但没有 server.conf。这通常会让 Easy-RSA 因旧锁文件或旧 PKI 卡住。
请先备份旧目录后重试，例如:
  docker rm -f $OVPN_CONTAINER_NAME 2>/dev/null || true
  mv $OVPN_INSTALL_DIR $backup_example 2>/dev/null || true
  bash openvpn-landing-setup.sh"
  fi
}

require_root() {
  [[ "$(id -u)" == "0" ]] || die "$1 需要 root 权限，请使用 root 重新运行脚本。"
}

ensure_curl() {
  if command -v curl >/dev/null 2>&1; then
    return
  fi

  require_root "安装 curl"

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl ca-certificates
  else
    die "需要 curl，但没有找到受支持的包管理器。"
  fi
}

start_docker_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service docker start >/dev/null 2>&1 || true
  fi
}

install_docker_engine() {
  require_root "安装 Docker"
  ensure_curl

  log "正在使用 Docker 官方脚本安装 Docker Engine..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  start_docker_service

  docker version >/dev/null 2>&1 || die "Docker 安装完成，但 docker 命令不可用。"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    start_docker_service
    return
  fi

  if [[ "$OVPN_AUTO_INSTALL_DOCKER" != "true" ]]; then
    die "未检测到 Docker，且已关闭自动安装 Docker。"
  fi

  install_docker_engine
}

compose_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf 'x86_64'
      ;;
    aarch64|arm64)
      printf 'aarch64'
      ;;
    armv7l|armv7)
      printf 'armv7'
      ;;
    *)
      die "当前架构不支持手动安装 Docker Compose: $(uname -m)"
      ;;
  esac
}

install_compose_plugin_with_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y docker-compose-plugin
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y docker-compose-plugin
  elif command -v yum >/dev/null 2>&1; then
    yum install -y docker-compose-plugin
  else
    return 1
  fi
}

install_compose_plugin_manually() {
  local arch
  local plugin_dir="/usr/local/lib/docker/cli-plugins"
  local plugin_path="$plugin_dir/docker-compose"

  require_root "安装 Docker Compose"
  ensure_curl
  arch="$(compose_arch)"

  mkdir -p "$plugin_dir"
  curl -fsSL \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$arch" \
    -o "$plugin_path"
  chmod +x "$plugin_path"
}

install_docker_compose_wrapper() {
  if command -v docker-compose >/dev/null 2>&1; then
    return
  fi

  require_root "安装 docker-compose 兼容命令"

  cat >/usr/local/bin/docker-compose <<'EOF'
#!/usr/bin/env sh
exec docker compose "$@"
EOF
  chmod +x /usr/local/bin/docker-compose
}

ensure_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    install_docker_compose_wrapper
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    return
  fi

  if [[ "$OVPN_AUTO_INSTALL_COMPOSE" != "true" ]]; then
    die "未检测到 Docker Compose，且已关闭自动安装 Compose。"
  fi

  require_root "安装 Docker Compose"
  log "正在安装 Docker Compose 插件..."

  install_compose_plugin_with_package_manager || true

  if ! docker compose version >/dev/null 2>&1; then
    log "包管理器未成功安装 Docker Compose 插件，改用 GitHub release 手动下载..."
    install_compose_plugin_manually
  fi

  docker compose version >/dev/null 2>&1 || die "Docker Compose 安装失败。"
  install_docker_compose_wrapper
}

pull_openvpn_ui_image() {
  if [[ "$OVPN_PULL_OPENVPN_UI" != "true" ]]; then
    return
  fi

  log "正在下载 OpenVPN-UI 镜像: $OVPN_IMAGE"
  docker pull "$OVPN_IMAGE"
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    printf 'docker compose'
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    printf 'docker-compose'
    return
  fi

  die "需要 docker compose 或 docker-compose。"
}

wait_for_web() {
  local url="http://127.0.0.1:$OVPN_WEB_PORT/login"
  local i

  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  for i in $(seq 1 60); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

wait_for_openvpn_config() {
  local attempts="${OVPN_INIT_WAIT_ATTEMPTS:-60}"
  local sleep_seconds="${OVPN_INIT_WAIT_SECONDS:-2}"
  local i

  log "正在等待 OpenVPN 初始化文件生成..."

  for i in $(seq 1 "$attempts"); do
    if docker exec "$OVPN_CONTAINER_NAME" test -f /data/server.conf >/dev/null 2>&1; then
      log "OpenVPN 初始化文件已生成。"
      return 0
    fi
    sleep "$sleep_seconds"
  done

  return 1
}

apply_auth_setting() {
  if docker exec "$OVPN_CONTAINER_NAME" /usr/bin/docker-entrypoint.sh auth "$OVPN_ENABLE_AUTH" >/dev/null; then
    log "VPN 账号密码验证已设置为: $OVPN_ENABLE_AUTH"
  else
    warn "自动设置 VPN 账号验证失败，请在 Web 面板或 server.conf 中确认。"
  fi
}

normalize_redirect_gateway() {
  if [[ "$OVPN_ENABLE_IPV6" == "true" || "$OVPN_ENABLE_GATEWAY" != "true" ]]; then
    return
  fi

  if docker exec "$OVPN_CONTAINER_NAME" sed -i \
    's/redirect-gateway def1 ipv6 bypass-dhcp/redirect-gateway def1 bypass-dhcp/g' \
    /data/server.conf >/dev/null; then
    log "已将 redirect-gateway 修正为仅 IPv4。"
  else
    warn "修正 redirect-gateway 失败，请手动检查 /data/server.conf。"
  fi
}

normalize_client_profile_proto() {
  local client_file="$OVPN_INSTALL_DIR/data/clients/$OVPN_CLIENT_NAME.ovpn"

  if [[ ! -f "$client_file" ]]; then
    warn "未找到客户端配置文件，无法修正客户端协议: $client_file"
    return 1
  fi

  if grep -q '^proto tcp-server$' "$client_file"; then
    sed -i 's/^proto tcp-server$/proto tcp-client/' "$client_file"
    log "已将客户端配置协议修正为 tcp-client: $client_file"
  fi
}

create_initial_client() {
  OVPN_CLIENT_CREATED=false

  if [[ "$OVPN_CREATE_CLIENT" != "true" ]]; then
    return
  fi

  if docker exec "$OVPN_CONTAINER_NAME" /usr/bin/docker-entrypoint.sh \
    genclient "$OVPN_CLIENT_NAME" "$OVPN_CLIENT_REMOTE_HOST" "$OVPN_CLIENT_REMOTE_PORT" "" "" "false" >/dev/null; then
    normalize_client_profile_proto || true
    OVPN_CLIENT_CREATED=true
    log "初始客户端配置已创建: $OVPN_INSTALL_DIR/data/clients/$OVPN_CLIENT_NAME.ovpn"
    log "客户端 remote 目标: $OVPN_CLIENT_REMOTE_HOST:$OVPN_CLIENT_REMOTE_PORT"
  else
    warn "自动创建初始客户端失败，请在 Web 面板中创建，或手动执行 genclient。"
  fi
}

print_admin_warning() {
  printf '\033[33m%s\033[0m\n' "重要提醒：请立即登录 Web 面板，手动修改默认管理员账号和密码。脚本不会保存或重置管理员凭据。"
}

deploy() {
  local cmd
  local client_summary
  local openvpn_ready=false

  OVPN_CLIENT_CREATED=false

  [[ "$(id -u)" == "0" ]] || warn "当前不是 root 用户；如果 Docker 权限不足，请使用 root 运行。"

  ensure_clean_data_dir

  ensure_docker
  ensure_docker_compose
  pull_openvpn_ui_image
  render_files

  cmd="$(compose_cmd)"
  log "正在启动容器..."
  (cd "$OVPN_INSTALL_DIR" && $cmd up -d)

  if wait_for_web; then
    log "Web 面板已启动。"
  else
    warn "Web 面板在等待时间内未就绪，请检查: docker logs $OVPN_CONTAINER_NAME"
  fi

  if wait_for_openvpn_config; then
    openvpn_ready=true
    apply_auth_setting
    normalize_redirect_gateway
    create_initial_client
  else
    warn "OpenVPN 初始化文件在等待时间内未生成，已跳过认证设置、网关修正和客户端生成。"
    warn "请检查: docker logs $OVPN_CONTAINER_NAME"
  fi

  log "正在重启容器，让配置完全生效..."
  docker restart "$OVPN_CONTAINER_NAME" >/dev/null

  if [[ "$OVPN_CREATE_CLIENT" == "true" && "$OVPN_CLIENT_CREATED" == "true" ]]; then
    client_summary="初始客户端配置:
  $OVPN_INSTALL_DIR/data/clients/$OVPN_CLIENT_NAME.ovpn
  remote $OVPN_CLIENT_REMOTE_HOST $OVPN_CLIENT_REMOTE_PORT"
  elif [[ "$OVPN_CREATE_CLIENT" == "true" && "$openvpn_ready" == "true" ]]; then
    client_summary="初始客户端配置:
  未成功创建，请在 Web 面板中创建，或手动执行 genclient。"
  elif [[ "$OVPN_CREATE_CLIENT" == "true" ]]; then
    client_summary="初始客户端配置:
  OpenVPN 初始化未完成，暂未创建。"
  else
    client_summary="初始客户端配置:
  未启用"
  fi

  cat <<EOF

部署完成。
Web 面板:
  http://$OVPN_SERVER_HOST:$OVPN_WEB_PORT

OpenVPN 服务:
  tcp://$OVPN_SERVER_HOST:$OVPN_PORT

nyanpass 转发示例:
  入口端口 -> $OVPN_SERVER_HOST:$OVPN_PORT TCP

$client_summary

常用检查命令:
  cd $OVPN_INSTALL_DIR
  docker compose ps
  docker logs $OVPN_CONTAINER_NAME --tail 100
  ss -lntup | grep -E '$OVPN_WEB_PORT|$OVPN_PORT'

后续操作:
  1. 登录 Web 面板。
  2. 如果启用了 VPN 账号验证，先创建 VPN 账号。
  3. 将生成的 .ovpn 导入电脑或 OpenWrt。
  4. 后续需要更多用户或客户端时，在 Web 面板里继续创建。
EOF

  print_admin_warning
}

main() {
  RENDER_ONLY=false

  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
    --render-only)
      RENDER_ONLY=true
      OVPN_INSTALL_DIR="${2:-${OVPN_INSTALL_DIR:-}}"
      [[ -n "$OVPN_INSTALL_DIR" ]] || die "--render-only 需要指定输出目录。"
      collect_from_env
      ;;
    "")
      collect_interactive
      ;;
    *)
      usage
      die "未知参数: $1"
      ;;
  esac

  validate_config

  if [[ "$RENDER_ONLY" == "true" ]]; then
    render_files
    log "已生成配置文件到: $OVPN_INSTALL_DIR"
  else
    deploy
  fi
}

main "$@"
