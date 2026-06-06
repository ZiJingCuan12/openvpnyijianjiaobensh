#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/zeek-openvpn-audit.conf"
INTERFACE="eth0"
LOCAL_IP=""
PORT_RANGE="2000-65535"
LOG_FILE="/opt/zeek/logs/current/conn.log"
ZEEK_PREFIX="/opt/zeek"
NTOPNG_INTERFACE=""
NTOPNG_WEB_BIND="0.0.0.0"
NTOPNG_WEB_PORT="3000"
FORMAT="table"
TAIL_LINES=0
INCLUDE_NOISE=false
SUSPECT_MIN_SECONDS=30
SUSPECT_MIN_BYTES=1048576
NOISE_MAX_SECONDS=10
NOISE_MAX_BYTES=65536
REPORT_MODE=false
RISK_ONLY=false
OPENVPN_ONLY=false
PRINT_MENU=""

PORT_MIN=2000
PORT_MAX=65535

info() {
  printf '\033[32m[INFO]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Zeek OpenVPN 审计菜单脚本

用途:
  在入口/出口转发机上部署 Zeek + zeek-spicy-openvpn，并生成 OpenVPN 白名单识别报表。
  本脚本只检测和报表，不自动封禁、不自动断开连接。

用法:
  bash zeek-openvpn-audit-menu.sh
  bash zeek-openvpn-audit-menu.sh --config /etc/zeek-openvpn-audit.conf --report --tail 5000
  bash zeek-openvpn-audit-menu.sh --risk-ports --tail 5000
  bash zeek-openvpn-audit-menu.sh --openvpn-ports --tail 5000

常用选项:
  --config PATH              配置文件路径，默认 /etc/zeek-openvpn-audit.conf
  --report                   非交互模式，直接输出报表
  --risk-ports               一键输出风险端口，只显示 SUSPECT/CHECK
  --openvpn-ports            一键输出 OpenVPN 端口，只显示 OK_OPENVPN
  --log PATH                 Zeek conn.log 路径
  --local-ip IP              本机入口 IP；填 all 表示不过滤本机 IP
  --ports MIN-MAX            客户入口端口范围，默认 2000-65535
  --tail N                   只读取最后 N 行；默认 0 表示读取整个文件
  --format table|csv|json    报表格式，默认 table
  --include-noise            显示短失败连接/扫描噪音
  --suspect-seconds N        非 OpenVPN 可疑连接最小时长，默认 30
  --suspect-bytes N          非 OpenVPN 可疑连接最小总字节数，默认 1048576
  --print-menu main|install|config|report|web
                             仅打印指定菜单，便于检查脚本内容
  -h, --help                 显示帮助

状态说明:
  OK_OPENVPN      service 包含 spicy_openvpn，符合 OpenVPN 白名单
  SUSPECT         超过时长和流量阈值，但未识别为 OpenVPN
  CHECK           非 OpenVPN，且未达到 SUSPECT 阈值
  IGNORED_NOISE   短失败连接/扫描噪音，默认隐藏
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "此操作需要 root 权限"
}

prompt_default() {
  local label="$1"
  local default_value="$2"
  local value

  read -r -p "$label [$default_value]: " value
  printf '%s' "${value:-$default_value}"
}

confirm() {
  local label="$1"
  local default_value="${2:-N}"
  local answer

  read -r -p "$label [$default_value]: " answer
  answer="${answer:-$default_value}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

pause_enter() {
  read -r -p "按回车返回菜单..." _
}

parse_port_range() {
  local ports="$1"

  [[ "$ports" =~ ^[0-9]+-[0-9]+$ ]] || die "端口范围格式必须是 MIN-MAX，例如 2000-65535"
  PORT_MIN="${ports%-*}"
  PORT_MAX="${ports#*-}"
  (( PORT_MIN >= 1 && PORT_MIN <= PORT_MAX && PORT_MAX <= 65535 )) || die "端口范围必须在 1-65535 之间"
  PORT_RANGE="$ports"
}

validate_number() {
  local value="$1"
  local label="$2"

  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "$label 必须是数字"
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  parse_port_range "$PORT_RANGE"
}

save_config() {
  local target="$CONFIG_FILE"
  local tmp="${target}.tmp.$$"

  require_root
  mkdir -p "$(dirname "$target")"
  umask 077
  cat >"$tmp" <<EOF
INTERFACE="$INTERFACE"
LOCAL_IP="$LOCAL_IP"
PORT_RANGE="$PORT_RANGE"
LOG_FILE="$LOG_FILE"
ZEEK_PREFIX="$ZEEK_PREFIX"
NTOPNG_INTERFACE="$NTOPNG_INTERFACE"
NTOPNG_WEB_BIND="$NTOPNG_WEB_BIND"
NTOPNG_WEB_PORT="$NTOPNG_WEB_PORT"
SUSPECT_MIN_SECONDS="$SUSPECT_MIN_SECONDS"
SUSPECT_MIN_BYTES="$SUSPECT_MIN_BYTES"
NOISE_MAX_SECONDS="$NOISE_MAX_SECONDS"
NOISE_MAX_BYTES="$NOISE_MAX_BYTES"
EOF
  mv "$tmp" "$target"
  chmod 0600 "$target"
  info "配置已保存: $target"
}

detect_local_ip() {
  ip -4 route get 8.8.8.8 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

detect_default_interface() {
  ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

list_ipv4_interfaces() {
  ip -o -4 addr show scope global 2>/dev/null | awk '{split($4, cidr, "/"); print $2 " " cidr[1] " " $4}' | sort -u
}

choose_interface_and_ip() {
  local default_iface
  local default_ip
  local selected
  local index=1
  local entries=()
  local line
  local iface
  local ip_addr

  require_cmd ip
  default_iface="$(detect_default_interface || true)"
  default_ip="$(detect_local_ip || true)"

  info "自动识别到的默认网卡: ${default_iface:-未识别}"
  info "自动识别到的本机出口 IP: ${default_ip:-未识别}"
  echo

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    entries+=("$line")
    printf '  %d. %s\n' "$index" "$line"
    index=$((index + 1))
  done < <(list_ipv4_interfaces)

  if [[ "${#entries[@]}" -eq 0 ]]; then
    warn "没有自动识别到 IPv4 网卡，请使用手动配置。"
    return 1
  fi

  echo "  8. 返回上一级"
  echo "  9. 返回主菜单"
  echo "  0. 退出"
  read -r -p "请选择监听网卡/IP: " selected

  case "$selected" in
    0)
      exit 0
      ;;
    8|9)
      return 0
      ;;
  esac

  [[ "$selected" =~ ^[0-9]+$ ]] || die "选择必须是数字"
  (( selected >= 1 && selected <= ${#entries[@]} )) || die "选择超出范围"

  iface="$(awk '{print $1}' <<<"${entries[$((selected - 1))]}")"
  ip_addr="$(awk '{print $2}' <<<"${entries[$((selected - 1))]}")"
  INTERFACE="$iface"
  LOCAL_IP="$ip_addr"
  [[ -z "$NTOPNG_INTERFACE" ]] && NTOPNG_INTERFACE="$iface"
  info "已选择网卡: $INTERFACE"
  info "已选择本机入口 IP: $LOCAL_IP"
}

zeek_bin() {
  printf '%s/bin/%s' "$ZEEK_PREFIX" "$1"
}

install_zeek_apt_repo() {
  local os_id=""
  local version_id=""
  local repo_id=""
  local repo_url=""
  local key_url=""

  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  os_id="${ID:-}"
  version_id="${VERSION_ID:-}"

  case "$os_id" in
    ubuntu)
      repo_id="xUbuntu_${version_id}"
      ;;
    debian)
      repo_id="Debian_${version_id}"
      ;;
    *)
      die "当前自动安装仅支持 Debian/Ubuntu，检测到: ${os_id:-unknown}"
      ;;
  esac

  repo_url="http://download.opensuse.org/repositories/security:/zeek/${repo_id}/"
  key_url="https://download.opensuse.org/repositories/security:zeek/${repo_id}/Release.key"

  info "正在添加 Zeek 官方 OBS 仓库: $repo_id"
  curl -fsSL "$key_url" | gpg --dearmor >/etc/apt/trusted.gpg.d/security_zeek.gpg
  printf 'deb %s /\n' "$repo_url" >/etc/apt/sources.list.d/security:zeek.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y zeek
}

install_dependencies_and_zeek() {
  require_root

  if command -v apt-get >/dev/null 2>&1; then
    info "正在安装基础依赖..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates gpg git perl libjson-pp-perl tcpdump
  else
    warn "未检测到 apt-get，请手动安装 curl/gpg/git/perl/tcpdump 和 Zeek。"
  fi

  if [[ -x "$(zeek_bin zeek)" ]]; then
    info "检测到 Zeek: $("$(zeek_bin zeek)" --version 2>/dev/null || true)"
  elif command -v apt-get >/dev/null 2>&1; then
    install_zeek_apt_repo
  else
    die "未找到 Zeek，且当前系统不支持自动安装。"
  fi

  info "安装/检查完成。"
}

install_openvpn_analyzer() {
  require_root
  [[ -x "$(zeek_bin zkg)" ]] || die "未找到 zkg，请先安装 Zeek。"

  info "正在初始化 zkg 配置..."
  "$(zeek_bin zkg)" autoconfig

  if "$(zeek_bin zkg)" list | grep -q 'zeek-spicy-openvpn'; then
    info "zeek-spicy-openvpn 已安装。"
  else
    info "正在安装 zeek-spicy-openvpn..."
    "$(zeek_bin zkg)" install https://github.com/corelight/zeek-spicy-openvpn
  fi

  info "正在确认 OpenVPN analyzer..."
  "$(zeek_bin zeek)" -NN Zeek::Spicy | grep -i openvpn || warn "未看到 OpenVPN analyzer 输出，请检查 zkg 安装结果。"
}

configure_zeek_files() {
  local local_zeek
  local node_cfg
  local filter

  require_root
  parse_port_range "$PORT_RANGE"
  local_zeek="$ZEEK_PREFIX/share/zeek/site/local.zeek"
  node_cfg="$ZEEK_PREFIX/etc/node.cfg"
  filter="tcp portrange ${PORT_MIN}-${PORT_MAX} or udp portrange ${PORT_MIN}-${PORT_MAX}"

  [[ -f "$local_zeek" ]] || die "找不到 local.zeek: $local_zeek"
  [[ -f "$node_cfg" ]] || die "找不到 node.cfg: $node_cfg"

  cp "$local_zeek" "${local_zeek}.bak.$(date +%F-%H%M%S)"
  sed -i '/^@load packages$/d' "$local_zeek"
  sed -i '/^redef LogAscii::use_json = /d' "$local_zeek"
  sed -i '/^redef ignore_checksums = /d' "$local_zeek"
  sed -i '/^redef PacketFilter::default_capture_filter = /d' "$local_zeek"
  cat >>"$local_zeek" <<EOF

@load packages
redef LogAscii::use_json = T;
redef ignore_checksums = T;
redef PacketFilter::default_capture_filter = "$filter";
EOF

  cp "$node_cfg" "${node_cfg}.bak.$(date +%F-%H%M%S)"
  if grep -q '^interface=' "$node_cfg"; then
    sed -i "0,/^interface=.*/s/^interface=.*/interface=${INTERFACE}/" "$node_cfg"
  else
    awk -v iface="$INTERFACE" '
      BEGIN { inserted = 0 }
      /^\[zeek\]/ && inserted == 0 { print; print "interface=" iface; inserted = 1; next }
      { print }
      END { if (inserted == 0) print "interface=" iface }
    ' "$node_cfg" >"${node_cfg}.tmp.$$"
    mv "${node_cfg}.tmp.$$" "$node_cfg"
  fi

  info "Zeek 监听接口已设置为: $INTERFACE"
  info "Zeek 抓包过滤已设置为: $filter"
}

configure_interactive() {
  INTERFACE="$(prompt_default "监听网卡" "$INTERFACE")"
  LOCAL_IP="$(prompt_default "本机入口 IP，填 all 表示不过滤" "${LOCAL_IP:-all}")"
  [[ "$LOCAL_IP" == "all" ]] && LOCAL_IP=""
  PORT_RANGE="$(prompt_default "客户入口端口范围" "$PORT_RANGE")"
  LOG_FILE="$(prompt_default "Zeek conn.log 路径" "$LOG_FILE")"
  ZEEK_PREFIX="$(prompt_default "Zeek 安装目录" "$ZEEK_PREFIX")"
  SUSPECT_MIN_SECONDS="$(prompt_default "SUSPECT 最小时长秒数" "$SUSPECT_MIN_SECONDS")"
  SUSPECT_MIN_BYTES="$(prompt_default "SUSPECT 最小总字节数" "$SUSPECT_MIN_BYTES")"

  parse_port_range "$PORT_RANGE"
  validate_number "$SUSPECT_MIN_SECONDS" "SUSPECT 最小时长秒数"
  validate_number "$SUSPECT_MIN_BYTES" "SUSPECT 最小总字节数"
  save_config
  configure_zeek_files
}

start_zeek() {
  require_root
  [[ -x "$(zeek_bin zeekctl)" ]] || die "未找到 zeekctl，请先安装 Zeek。"

  info "正在检查 Zeek 配置..."
  "$(zeek_bin zeekctl)" check
  info "正在部署/重启 Zeek..."
  "$(zeek_bin zeekctl)" deploy
}

show_status() {
  if [[ -x "$(zeek_bin zeekctl)" ]]; then
    "$(zeek_bin zeekctl)" status || true
  else
    warn "未找到 zeekctl: $(zeek_bin zeekctl)"
  fi

  if [[ -x "$(zeek_bin zeek)" ]]; then
    "$(zeek_bin zeek)" -NN Zeek::Spicy 2>/dev/null | grep -i openvpn || warn "未看到 OpenVPN analyzer。"
  fi
}

install_ntopng_web() {
  local version_id=""
  local os_id=""
  local codename=""
  local repo_id=""
  local repo_deb=""

  require_root
  if command -v ntopng >/dev/null 2>&1; then
    info "检测到 ntopng: $(ntopng --version 2>/dev/null | head -n 1 || true)"
    return 0
  fi

  command -v apt-get >/dev/null 2>&1 || die "ntopng 自动安装目前仅支持 Debian/Ubuntu apt 系统"
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  os_id="${ID:-}"
  version_id="${VERSION_ID:-}"
  codename="${VERSION_CODENAME:-}"

  case "$os_id" in
    ubuntu)
      repo_id="$version_id"
      ;;
    debian)
      repo_id="$codename"
      ;;
    *)
      die "ntopng 自动安装仅支持 Debian/Ubuntu，检测到: ${os_id:-unknown}"
      ;;
  esac

  repo_deb="https://packages.ntop.org/apt-stable/${repo_id}/all/apt-ntop-stable.deb"

  info "正在安装 ntopng 官方稳定版仓库包: $repo_deb"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common wget whiptail ca-certificates gnupg lsb-release
  if [[ "$os_id" == "ubuntu" ]] && command -v add-apt-repository >/dev/null 2>&1; then
    add-apt-repository -y universe >/dev/null 2>&1 || true
  fi
  wget -qO /tmp/apt-ntop-stable.deb "$repo_deb"
  apt-get install -y /tmp/apt-ntop-stable.deb
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ntopng
  info "ntopng 安装完成。"
}

configure_ntopng_web() {
  local conf="/etc/ntopng/ntopng.conf"
  local iface="$NTOPNG_INTERFACE"

  require_root
  [[ -f "$conf" ]] || die "找不到 ntopng 配置文件: $conf，请先安装 ntopng。"

  [[ -n "$iface" ]] || iface="$INTERFACE"
  iface="$(prompt_default "ntopng 监听网卡" "$iface")"
  NTOPNG_INTERFACE="$iface"
  NTOPNG_WEB_BIND="$(prompt_default "ntopng Web 监听地址" "$NTOPNG_WEB_BIND")"
  NTOPNG_WEB_PORT="$(prompt_default "ntopng Web 端口" "$NTOPNG_WEB_PORT")"
  [[ "$NTOPNG_WEB_PORT" =~ ^[0-9]+$ ]] || die "ntopng Web 端口必须是整数"

  cp "$conf" "${conf}.bak.$(date +%F-%H%M%S)"
  sed -i '/^-i=/d' "$conf"
  sed -i '/^--http-port=/d' "$conf"
  cat >>"$conf" <<EOF

-i=$NTOPNG_INTERFACE
--http-port=$NTOPNG_WEB_BIND:$NTOPNG_WEB_PORT
EOF

  save_config

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable ntopng >/dev/null 2>&1 || true
    systemctl restart ntopng
  else
    service ntopng restart
  fi

  info "ntopng Web 页面: http://$NTOPNG_WEB_BIND:$NTOPNG_WEB_PORT/"
  warn "如果绑定 0.0.0.0，请务必用安全组/防火墙限制访问来源。"
}

show_ntopng_status() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl status ntopng --no-pager || true
  elif command -v service >/dev/null 2>&1; then
    service ntopng status || true
  else
    warn "当前系统没有 systemctl/service，无法查看 ntopng 服务状态。"
  fi
}

show_config() {
  cat <<EOF
配置文件: $CONFIG_FILE
监听网卡: $INTERFACE
本机入口 IP: ${LOCAL_IP:-all}
端口范围: $PORT_RANGE
Zeek 日志: $LOG_FILE
Zeek 目录: $ZEEK_PREFIX
ntopng 网卡: ${NTOPNG_INTERFACE:-$INTERFACE}
ntopng Web: $NTOPNG_WEB_BIND:$NTOPNG_WEB_PORT
SUSPECT 最小时长: $SUSPECT_MIN_SECONDS 秒
SUSPECT 最小总字节数: $SUSPECT_MIN_BYTES
EOF
}

run_report() {
  local report_local_ip="$LOCAL_IP"

  parse_port_range "$PORT_RANGE"
  [[ -f "$LOG_FILE" ]] || die "日志文件不存在: $LOG_FILE"
  require_cmd perl

  if [[ -z "$report_local_ip" ]]; then
    report_local_ip="$(detect_local_ip || true)"
  elif [[ "$report_local_ip" == "all" ]]; then
    report_local_ip=""
  fi

  ZEEK_REPORT_LOG_FILE="$LOG_FILE" \
  ZEEK_REPORT_LOCAL_IP="$report_local_ip" \
  ZEEK_REPORT_PORT_MIN="$PORT_MIN" \
  ZEEK_REPORT_PORT_MAX="$PORT_MAX" \
  ZEEK_REPORT_FORMAT="$FORMAT" \
  ZEEK_REPORT_TAIL_LINES="$TAIL_LINES" \
  ZEEK_REPORT_INCLUDE_NOISE="$INCLUDE_NOISE" \
  ZEEK_REPORT_RISK_ONLY="$RISK_ONLY" \
  ZEEK_REPORT_OPENVPN_ONLY="$OPENVPN_ONLY" \
  ZEEK_REPORT_SUSPECT_MIN_SECONDS="$SUSPECT_MIN_SECONDS" \
  ZEEK_REPORT_SUSPECT_MIN_BYTES="$SUSPECT_MIN_BYTES" \
  ZEEK_REPORT_NOISE_MAX_SECONDS="$NOISE_MAX_SECONDS" \
  ZEEK_REPORT_NOISE_MAX_BYTES="$NOISE_MAX_BYTES" \
  perl -MJSON::PP -MPOSIX=strftime -CS - <<'PERL'
use strict;
use warnings;

binmode STDOUT, ':encoding(UTF-8)';

my $json = JSON::PP->new->utf8->canonical;
my $log_file = $ENV{ZEEK_REPORT_LOG_FILE};
my $local_ip = $ENV{ZEEK_REPORT_LOCAL_IP} // '';
my $port_min = int($ENV{ZEEK_REPORT_PORT_MIN});
my $port_max = int($ENV{ZEEK_REPORT_PORT_MAX});
my $format = $ENV{ZEEK_REPORT_FORMAT};
my $tail_lines = int($ENV{ZEEK_REPORT_TAIL_LINES});
my $include_noise = ($ENV{ZEEK_REPORT_INCLUDE_NOISE} // '') eq 'true';
my $risk_only = ($ENV{ZEEK_REPORT_RISK_ONLY} // '') eq 'true';
my $openvpn_only = ($ENV{ZEEK_REPORT_OPENVPN_ONLY} // '') eq 'true';
my $suspect_seconds = 0 + $ENV{ZEEK_REPORT_SUSPECT_MIN_SECONDS};
my $suspect_bytes = int($ENV{ZEEK_REPORT_SUSPECT_MIN_BYTES});
my $noise_seconds = 0 + $ENV{ZEEK_REPORT_NOISE_MAX_SECONDS};
my $noise_bytes = int($ENV{ZEEK_REPORT_NOISE_MAX_BYTES});

sub number {
  my ($value) = @_;
  return 0 if !defined $value || $value eq '';
  return 0 + $value;
}

sub iso_time {
  my ($ts) = @_;
  return '-' if !$ts || $ts <= 0;
  return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(int($ts)));
}

sub classify {
  my ($service, $duration, $orig_bytes, $resp_bytes) = @_;
  my $total = $orig_bytes + $resp_bytes;
  return 'OK_OPENVPN' if $service =~ /spicy_openvpn/;
  return 'IGNORED_NOISE' if $resp_bytes == 0 && $total <= $noise_bytes && $duration <= $noise_seconds;
  return 'SUSPECT' if $duration >= $suspect_seconds && $total >= $suspect_bytes;
  return 'CHECK';
}

sub read_lines {
  open my $fh, '<:encoding(UTF-8)', $log_file or die "[ERROR] 无法读取日志文件: $log_file: $!\n";
  my @lines;
  while (my $line = <$fh>) {
    if ($tail_lines > 0) {
      push @lines, $line;
      shift @lines while @lines > $tail_lines;
    } else {
      push @lines, $line;
    }
  }
  close $fh;
  return @lines;
}

sub csv_escape {
  my ($value) = @_;
  $value = '' if !defined $value;
  $value =~ s/"/""/g;
  return qq("$value");
}

my %groups;
for my $line (read_lines()) {
  chomp $line;
  next if $line eq '';

  my $item;
  eval { $item = $json->decode($line); 1 } or next;

  my $resp_port = int(number($item->{'id.resp_p'}));
  next if $resp_port < $port_min || $resp_port > $port_max;
  next if $local_ip ne '' && (($item->{'id.resp_h'} // '') ne $local_ip);

  my $service = $item->{service} // '-';
  my $duration = number($item->{duration});
  my $orig_bytes = int(number($item->{orig_bytes}));
  my $resp_bytes = int(number($item->{resp_bytes}));
  my $status = classify($service, $duration, $orig_bytes, $resp_bytes);
  next if $status eq 'IGNORED_NOISE' && !$include_noise;
  next if $risk_only && ($status eq 'OK_OPENVPN' || $status eq 'IGNORED_NOISE');
  next if $openvpn_only && $status ne 'OK_OPENVPN';

  my $client_ip = $item->{'id.orig_h'} // '-';
  my $proto = $item->{proto} // '-';
  my $state = $item->{conn_state} // '-';
  my $key = join "\x1f", $status, $client_ip, $resp_port, $proto, $service;

  if (!exists $groups{$key}) {
    $groups{$key} = {
      status => $status,
      client_ip => $client_ip,
      port => $resp_port,
      proto => $proto,
      service => $service,
      connections => 0,
      duration_s => 0,
      orig_bytes => 0,
      resp_bytes => 0,
      total_bytes => 0,
      last_ts => 0,
      states => {},
    };
  }

  my $group = $groups{$key};
  $group->{connections}++;
  $group->{duration_s} += $duration;
  $group->{orig_bytes} += $orig_bytes;
  $group->{resp_bytes} += $resp_bytes;
  $group->{total_bytes} += $orig_bytes + $resp_bytes;
  $group->{last_ts} = number($item->{ts}) if number($item->{ts}) > $group->{last_ts};
  $group->{states}{$state} = 1;
}

my %status_order = (
  SUSPECT => 0,
  CHECK => 1,
  OK_OPENVPN => 2,
  IGNORED_NOISE => 3,
);

my @rows = map {
  my %row = %$_;
  $row{duration_s} = sprintf('%.3f', $row{duration_s});
  $row{duration_s} =~ s/\.?0+$//;
  $row{last_seen} = iso_time(delete $row{last_ts});
  $row{states} = join ',', sort keys %{$row{states}};
  \%row;
} values %groups;

@rows = sort {
  ($status_order{$a->{status}} // 9) <=> ($status_order{$b->{status}} // 9)
    || $a->{port} <=> $b->{port}
    || $a->{client_ip} cmp $b->{client_ip}
    || $a->{service} cmp $b->{service}
} @rows;

my @fields = qw(status client_ip port proto service connections duration_s orig_bytes resp_bytes total_bytes last_seen states);
my @field_names = qw(状态 客户IP 端口 协议 服务 连接数 持续秒 原始字节 响应字节 总字节 最后出现 连接状态);
if ($risk_only || $openvpn_only) {
  @fields = qw(status client_ip port proto service connections duration_s orig_bytes resp_bytes total_bytes last_seen);
  @field_names = qw(状态 客户IP 端口 协议 服务 连接数 持续秒 原始字节 响应字节 总字节 最后出现);
}

if ($format eq 'json') {
  my @json_rows;
  for my $row (@rows) {
    my %translated;
    for my $i (0 .. $#fields) {
      $translated{$field_names[$i]} = $row->{$fields[$i]};
    }
    push @json_rows, \%translated;
  }
  print $json->pretty->encode(\@json_rows);
  exit 0;
}

if ($format eq 'csv') {
  print join(',', map { csv_escape($_) } @field_names), "\n";
  for my $row (@rows) {
    print join(',', map { csv_escape($row->{$_}) } @fields), "\n";
  }
  exit 0;
}

my @headers = @field_names;
my @table_rows = (
  \@headers,
  map {
    my $row = $_;
    [ map { $row->{$_} } @fields ]
  } @rows
);

my @widths;
for my $row (@table_rows) {
  for my $i (0 .. $#$row) {
    my $len = length($row->[$i] // '');
    $widths[$i] = $len if !defined $widths[$i] || $len > $widths[$i];
  }
}

for my $row (@table_rows) {
  my @cells;
  for my $i (0 .. $#$row) {
    push @cells, sprintf('%-*s', $widths[$i], $row->[$i] // '');
  }
  print join('  ', @cells), "\n";
}
PERL
}

interactive_report() {
  RISK_ONLY=false
  FORMAT="$(prompt_default "报表格式 table/csv/json" "$FORMAT")"
  [[ "$FORMAT" =~ ^(table|csv|json)$ ]] || die "报表格式只能是 table、csv 或 json"
  TAIL_LINES="$(prompt_default "读取最后 N 行，0 表示全部" "$TAIL_LINES")"
  [[ "$TAIL_LINES" =~ ^[0-9]+$ ]] || die "tail 必须是非负整数"

  if confirm "是否显示扫描噪音" "N"; then
    INCLUDE_NOISE=true
  else
    INCLUDE_NOISE=false
  fi

  run_report
}

risk_ports_report() {
  RISK_ONLY=true
  OPENVPN_ONLY=false
  FORMAT="$(prompt_default "风险端口报表格式 table/csv/json" "$FORMAT")"
  [[ "$FORMAT" =~ ^(table|csv|json)$ ]] || die "报表格式只能是 table、csv 或 json"
  TAIL_LINES="$(prompt_default "读取最后 N 行，0 表示全部" "$TAIL_LINES")"
  [[ "$TAIL_LINES" =~ ^[0-9]+$ ]] || die "tail 必须是非负整数"
  INCLUDE_NOISE=false
  run_report
}

openvpn_ports_report() {
  RISK_ONLY=false
  OPENVPN_ONLY=true
  FORMAT="$(prompt_default "OpenVPN 端口报表格式 table/csv/json" "$FORMAT")"
  [[ "$FORMAT" =~ ^(table|csv|json)$ ]] || die "报表格式只能是 table、csv 或 json"
  TAIL_LINES="$(prompt_default "读取最后 N 行，0 表示全部" "$TAIL_LINES")"
  [[ "$TAIL_LINES" =~ ^[0-9]+$ ]] || die "tail 必须是非负整数"
  INCLUDE_NOISE=false
  run_report
}

export_csv_report() {
  local output

  output="$(prompt_default "CSV 输出路径" "/tmp/zeek-openvpn-report.csv")"
  FORMAT="csv"
  RISK_ONLY=false
  OPENVPN_ONLY=false
  run_report >"$output"
  info "CSV 报表已导出: $output"
}

export_risk_csv_report() {
  local output

  output="$(prompt_default "风险端口 CSV 输出路径" "/tmp/zeek-openvpn-risk-ports.csv")"
  FORMAT="csv"
  RISK_ONLY=true
  OPENVPN_ONLY=false
  run_report >"$output"
  info "风险端口 CSV 报表已导出: $output"
}

parse_cli_overrides() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        shift 2
        ;;
      --report)
        REPORT_MODE=true
        shift
        ;;
      --risk-ports)
        REPORT_MODE=true
        RISK_ONLY=true
        OPENVPN_ONLY=false
        shift
        ;;
      --openvpn-ports)
        REPORT_MODE=true
        RISK_ONLY=false
        OPENVPN_ONLY=true
        shift
        ;;
      --print-menu)
        PRINT_MENU="${2:-}"
        [[ "$PRINT_MENU" =~ ^(main|install|config|report|web)$ ]] || die "--print-menu 只能是 main、install、config、report 或 web"
        shift 2
        ;;
      --log)
        LOG_FILE="${2:-}"
        shift 2
        ;;
      --local-ip)
        LOCAL_IP="${2:-}"
        shift 2
        ;;
      --ports)
        parse_port_range "${2:-}"
        shift 2
        ;;
      --tail)
        TAIL_LINES="${2:-}"
        [[ "$TAIL_LINES" =~ ^[0-9]+$ ]] || die "--tail 必须是非负整数"
        shift 2
        ;;
      --format)
        FORMAT="${2:-}"
        [[ "$FORMAT" =~ ^(table|csv|json)$ ]] || die "--format 只能是 table、csv 或 json"
        shift 2
        ;;
      --include-noise)
        INCLUDE_NOISE=true
        shift
        ;;
      --suspect-seconds)
        SUSPECT_MIN_SECONDS="${2:-}"
        validate_number "$SUSPECT_MIN_SECONDS" "--suspect-seconds"
        shift 2
        ;;
      --suspect-bytes)
        SUSPECT_MIN_BYTES="${2:-}"
        [[ "$SUSPECT_MIN_BYTES" =~ ^[0-9]+$ ]] || die "--suspect-bytes 必须是整数"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "未知参数: $1"
        ;;
    esac
  done
}

parse_config_path() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        CONFIG_FILE="${2:-}"
        [[ -n "$CONFIG_FILE" ]] || die "--config 需要路径"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --report|--risk-ports|--openvpn-ports|--include-noise)
        shift
        ;;
      --print-menu|--log|--local-ip|--ports|--tail|--format|--suspect-seconds|--suspect-bytes)
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
}

show_main_menu() {
  cat <<EOF

Zeek OpenVPN 审计菜单脚本

当前配置:
  监听网卡: $INTERFACE
  本机入口 IP: ${LOCAL_IP:-all}
  端口范围: $PORT_RANGE
  Zeek 日志: $LOG_FILE

1. 安装和检查
2. 配置
3. 报表
4. Web 页面
5. 查看状态
6. 显示当前配置
0. 退出
EOF
}

print_return_items() {
  cat <<'EOF'
8. 返回上一级
9. 返回主菜单
0. 退出
EOF
}

show_install_menu() {
  cat <<'EOF'

安装和检查

1. 安装/检查依赖和 Zeek
2. 安装/检查 OpenVPN analyzer
3. 一键安装 Zeek + OpenVPN analyzer
EOF
  print_return_items
}

show_config_menu() {
  cat <<EOF

配置

当前监听网卡: $INTERFACE
当前本机入口 IP: ${LOCAL_IP:-all}
当前端口范围: $PORT_RANGE

1. 自动识别并选择网卡/IP
2. 手动配置 Zeek 监听和过滤
3. 应用当前配置到 Zeek
4. 启动/重启 Zeek
5. 显示当前配置
EOF
  print_return_items
}

show_report_menu() {
  cat <<'EOF'

报表

1. 生成完整报表
2. 一键输出风险端口
3. 一键输出 OpenVPN 端口
4. 导出完整 CSV 报表
5. 导出风险端口 CSV 报表
EOF
  print_return_items
}

show_web_menu() {
  cat <<EOF

Web 页面

当前 ntopng 监听网卡: ${NTOPNG_INTERFACE:-$INTERFACE}
当前 ntopng Web: $NTOPNG_WEB_BIND:$NTOPNG_WEB_PORT

1. 安装/检查 ntopng Web 页面
2. 配置 ntopng 监听网卡和端口
3. 查看 ntopng 状态
EOF
  print_return_items
}

print_selected_menu() {
  case "$1" in
    main)
      show_main_menu
      ;;
    install)
      show_install_menu
      ;;
    config)
      show_config_menu
      ;;
    report)
      show_report_menu
      ;;
    web)
      show_web_menu
      ;;
  esac
}

install_menu() {
  local choice

  while true; do
    show_install_menu
    read -r -p "请选择 [0-3/8/9]: " choice
    case "$choice" in
      1)
        install_dependencies_and_zeek
        pause_enter
        ;;
      2)
        install_openvpn_analyzer
        pause_enter
        ;;
      3)
        install_dependencies_and_zeek
        install_openvpn_analyzer
        pause_enter
        ;;
      8|9)
        return 0
        ;;
      0)
        exit 0
        ;;
      *)
        warn "无效选择: $choice"
        ;;
    esac
  done
}

config_menu() {
  local choice

  while true; do
    show_config_menu
    read -r -p "请选择 [0-5/8/9]: " choice
    case "$choice" in
      1)
        choose_interface_and_ip || true
        save_config
        pause_enter
        ;;
      2)
        configure_interactive
        pause_enter
        ;;
      3)
        configure_zeek_files
        pause_enter
        ;;
      4)
        start_zeek
        pause_enter
        ;;
      5)
        show_config
        pause_enter
        ;;
      8|9)
        return 0
        ;;
      0)
        exit 0
        ;;
      *)
        warn "无效选择: $choice"
        ;;
    esac
  done
}

report_menu() {
  local choice

  while true; do
    show_report_menu
    read -r -p "请选择 [0-5/8/9]: " choice
    case "$choice" in
      1)
        interactive_report
        pause_enter
        ;;
      2)
        risk_ports_report
        pause_enter
        ;;
      3)
        openvpn_ports_report
        pause_enter
        ;;
      4)
        export_csv_report
        pause_enter
        ;;
      5)
        export_risk_csv_report
        pause_enter
        ;;
      8|9)
        return 0
        ;;
      0)
        exit 0
        ;;
      *)
        warn "无效选择: $choice"
        ;;
    esac
  done
}

web_menu() {
  local choice

  while true; do
    show_web_menu
    read -r -p "请选择 [0-3/8/9]: " choice
    case "$choice" in
      1)
        install_ntopng_web
        pause_enter
        ;;
      2)
        configure_ntopng_web
        pause_enter
        ;;
      3)
        show_ntopng_status
        pause_enter
        ;;
      8|9)
        return 0
        ;;
      0)
        exit 0
        ;;
      *)
        warn "无效选择: $choice"
        ;;
    esac
  done
}

main_menu() {
  local choice

  while true; do
    show_main_menu
    read -r -p "请选择 [0-6]: " choice
    case "$choice" in
      1)
        install_menu
        ;;
      2)
        config_menu
        ;;
      3)
        report_menu
        ;;
      4)
        web_menu
        ;;
      5)
        show_status
        pause_enter
        ;;
      6)
        show_config
        pause_enter
        ;;
      0)
        exit 0
        ;;
      *)
        warn "无效选择: $choice"
        ;;
    esac
  done
}

main() {
  parse_config_path "$@"
  load_config
  parse_cli_overrides "$@"

  if [[ -n "$PRINT_MENU" ]]; then
    print_selected_menu "$PRINT_MENU"
    exit 0
  fi

  if [[ "$REPORT_MODE" == "true" ]]; then
    run_report
    exit 0
  fi

  main_menu
}

main "$@"
