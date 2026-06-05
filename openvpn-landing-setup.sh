#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2026.06.05"

usage() {
  cat <<'EOF'
OpenVPN 落地机一键配置脚本

用法:
  bash openvpn-landing-setup.sh
  bash openvpn-landing-setup.sh --legacy-interactive
  bash openvpn-landing-setup.sh --render-only /tmp/openvpn-render

说明:
  - 自动部署 yyxx/openvpn，并使用镜像自带 Web UI 做可视化管理。
  - 默认使用 OpenVPN TCP，适合 IEPL/nyanpass 的 TCP 端口转发。
  - 可选集成 sing-box TProxy 后置 SOCKS5 分流，支持按 OpenVPN 客户端 IP 分流 TCP/UDP。
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
  OVPN_ENABLE_PROXY
  OVPN_PROXY_CLIENTS_JSON
  OVPN_PROXY_CLIENTS_FILE
  OVPN_PROXY_UNMATCHED_POLICY
  OVPN_PROXY_DASHBOARD
  SING_BOX_IMAGE
  SING_BOX_CONTAINER_NAME
  SING_BOX_DASHBOARD_PUBLIC
  SING_BOX_TPROXY_PORT
  SING_BOX_API_ADDR
  SING_BOX_API_SECRET
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

addr_port() {
  local addr="$1"

  printf '%s' "${addr##*:}"
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
  OVPN_ENABLE_AUTH="$(normalize_bool "${OVPN_ENABLE_AUTH:-false}")"
  OVPN_AUTO_INSTALL_DOCKER="$(normalize_bool "${OVPN_AUTO_INSTALL_DOCKER:-true}")"
  OVPN_AUTO_INSTALL_COMPOSE="$(normalize_bool "${OVPN_AUTO_INSTALL_COMPOSE:-true}")"
  OVPN_PULL_OPENVPN_UI="$(normalize_bool "${OVPN_PULL_OPENVPN_UI:-true}")"
  OVPN_LANDING_IPV4="${OVPN_LANDING_IPV4:-$OVPN_SERVER_HOST}"
  OVPN_CREATE_CLIENT="$(normalize_bool "${OVPN_CREATE_CLIENT:-true}")"
  OVPN_CLIENT_NAME="${OVPN_CLIENT_NAME:-client1}"
  OVPN_USE_RELAY="$(normalize_bool "${OVPN_USE_RELAY:-false}")"
  OVPN_RELAY_HOST="${OVPN_RELAY_HOST:-}"
  OVPN_RELAY_PORT="${OVPN_RELAY_PORT:-$OVPN_PORT}"
  OVPN_ENABLE_PROXY="$(normalize_bool "${OVPN_ENABLE_PROXY:-false}")"
  OVPN_PROXY_CLIENTS_FILE="${OVPN_PROXY_CLIENTS_FILE:-$OVPN_INSTALL_DIR/proxy-clients.json}"
  OVPN_PROXY_CLIENTS_JSON="${OVPN_PROXY_CLIENTS_JSON:-}"
  OVPN_PROXY_UNMATCHED_POLICY="${OVPN_PROXY_UNMATCHED_POLICY:-block}"
  OVPN_PROXY_DASHBOARD="$(normalize_bool "${OVPN_PROXY_DASHBOARD:-true}")"
  SING_BOX_IMAGE="${SING_BOX_IMAGE:-ghcr.io/sagernet/sing-box:v1.12.12}"
  SING_BOX_CONTAINER_NAME="${SING_BOX_CONTAINER_NAME:-sing-box}"
  SING_BOX_DASHBOARD_PUBLIC="$(normalize_bool "${SING_BOX_DASHBOARD_PUBLIC:-false}")"
  SING_BOX_TPROXY_PORT="${SING_BOX_TPROXY_PORT:-12345}"
  if [[ -z "${SING_BOX_API_ADDR:-}" ]]; then
    if [[ "$SING_BOX_DASHBOARD_PUBLIC" == "true" ]]; then
      SING_BOX_API_ADDR="0.0.0.0:9090"
    else
      SING_BOX_API_ADDR="127.0.0.1:9090"
    fi
  fi
  SING_BOX_API_SECRET="${SING_BOX_API_SECRET:-sb_$(random_suffix)}"
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
  OVPN_ENABLE_AUTH="$(prompt_bool "是否启用 VPN 账号密码验证" "false")"
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

proxy_json_tool() {
  perl -MJSON::PP -MFile::Path=make_path -MFile::Basename=dirname - "$@" <<'PERL'
use strict;
use warnings;

my $json = JSON::PP->new->utf8->pretty->canonical->space_before(0)->space_after(1);
my $cmd = shift @ARGV // '';

sub read_doc {
  my ($file) = @_;
  return { clients => [] } if !-e $file;
  open my $fh, '<:raw', $file or die "无法读取 $file: $!\n";
  local $/;
  my $text = <$fh>;
  close $fh;
  return $json->decode($text || '{"clients":[]}');
}

sub write_doc {
  my ($file, $doc) = @_;
  make_path(dirname($file));
  open my $fh, '>:raw', $file or die "无法写入 $file: $!\n";
  print {$fh} $json->encode($doc);
  close $fh;
  chmod 0600, $file;
}

sub assert_name {
  my ($label, $value) = @_;
  die "$label 不能为空\n" if !defined($value) || $value eq '';
  die "$label 只允许字母、数字、点、下划线和短横线\n" if $value !~ /\A[A-Za-z0-9_.-]+\z/;
}

sub assert_host {
  my ($label, $value) = @_;
  die "$label 不能为空\n" if !defined($value) || $value eq '';
  die "$label 不合法\n" if $value !~ /\A[A-Za-z0-9_.:-]+\z/;
}

sub assert_profile_name {
  my ($value) = @_;
  die "OpenVPN Connect Profile Name 不能为空\n" if !defined($value) || $value eq '';
  die "OpenVPN Connect Profile Name 不能包含换行或制表符\n" if $value =~ /[\r\n\t]/;
}

sub assert_port {
  my ($label, $value) = @_;
  die "$label 必须是 1-65535 的数字端口\n" if !defined($value) || $value !~ /\A\d+\z/ || $value < 1 || $value > 65535;
}

sub validate_doc {
  my ($doc) = @_;
  die "proxy-clients.json 顶层必须包含 clients 数组\n" if ref($doc->{clients}) ne 'ARRAY';
  my (%names, %ips, %tags);
  for my $client (@{$doc->{clients}}) {
    die "clients 每一项必须是对象\n" if ref($client) ne 'HASH';
    assert_name('客户端名称', $client->{name});
    die "客户端固定 IP 不合法: $client->{name}\n" if !defined($client->{vpn_ip}) || $client->{vpn_ip} !~ /\A10\.8\.0\.(?:[2-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])\z/;
    die "客户端名称重复: $client->{name}\n" if $names{$client->{name}}++;
    die "客户端固定 IP 重复: $client->{vpn_ip}\n" if $ips{$client->{vpn_ip}}++;

    $client->{profile_name} = $client->{name} if !defined($client->{profile_name}) || $client->{profile_name} eq '';
    assert_profile_name($client->{profile_name});
    $client->{generate_client} = JSON::PP::true if !exists $client->{generate_client};
    $client->{remote_host} = '' if !defined $client->{remote_host};
    $client->{remote_port} = '' if !defined $client->{remote_port};
    if ($client->{remote_host} ne '') {
      assert_host('客户端 remote 主机', $client->{remote_host});
    }
    if ($client->{remote_port} ne '') {
      assert_port('客户端 remote 端口', $client->{remote_port});
      $client->{remote_port} = int($client->{remote_port});
    }
    $client->{unmatched_policy} = 'inherit' if !defined($client->{unmatched_policy}) || $client->{unmatched_policy} eq '';
    die "客户端 unmatched_policy 只能是 inherit、block 或 direct\n" if $client->{unmatched_policy} !~ /\A(?:inherit|block|direct)\z/;

    die "客户端 $client->{name} 缺少 socks 配置\n" if ref($client->{socks}) ne 'HASH';
    my $socks = $client->{socks};
    assert_name('SOCKS tag', $socks->{tag});
    assert_host('SOCKS 地址', $socks->{server});
    assert_port('SOCKS 端口', $socks->{port});
    $socks->{username} = '' if !defined $socks->{username};
    $socks->{password} = '' if !defined $socks->{password};
    $socks->{network} = 'tcp_udp' if !defined($socks->{network}) || $socks->{network} eq '';
    die "SOCKS network 只能是 tcp_udp、tcp_only 或 udp_over_tcp\n" if $socks->{network} !~ /\A(?:tcp_udp|tcp_only|udp_over_tcp)\z/;
    die "SOCKS tag 重复: $socks->{tag}\n" if $tags{$socks->{tag}}++;
  }
}

sub client_from_args {
  my ($name, $profile_name, $vpn_ip, $tag, $server, $port, $username, $password, $network, $unmatched_policy, $generate, $remote_host, $remote_port) = @_;
  $profile_name = $name if !defined($profile_name) || $profile_name eq '';
  return {
    name => $name,
    profile_name => $profile_name,
    vpn_ip => $vpn_ip,
    generate_client => ($generate // 'true') eq 'false' ? JSON::PP::false : JSON::PP::true,
    remote_host => $remote_host // '',
    remote_port => defined($remote_port) && $remote_port ne '' ? int($remote_port) : '',
    unmatched_policy => $unmatched_policy || 'inherit',
    socks => {
      tag => $tag,
      server => $server,
      port => int($port),
      username => $username // '',
      password => $password // '',
      network => $network || 'tcp_udp',
    },
  };
}

if ($cmd eq 'ensure') {
  my ($file) = @ARGV;
  write_doc($file, { clients => [] }) if !-e $file;
  exit 0;
}

if ($cmd eq 'write-json') {
  my ($file, $text) = @ARGV;
  my $doc = $json->decode($text);
  validate_doc($doc);
  write_doc($file, $doc);
  exit 0;
}

if ($cmd eq 'import') {
  my ($file, $src) = @ARGV;
  my $doc = read_doc($src);
  validate_doc($doc);
  write_doc($file, $doc);
  exit 0;
}

if ($cmd eq 'add' || $cmd eq 'edit') {
  my ($file, @rest) = @ARGV;
  my $new_client = client_from_args(@rest);
  my $doc = read_doc($file);
  my $found = 0;
  for my $i (0 .. $#{$doc->{clients}}) {
    if ($doc->{clients}[$i]{name} eq $new_client->{name}) {
      die "客户端已存在: $new_client->{name}\n" if $cmd eq 'add';
      $doc->{clients}[$i] = $new_client;
      $found = 1;
      last;
    }
  }
  die "客户端不存在: $new_client->{name}\n" if $cmd eq 'edit' && !$found;
  push @{$doc->{clients}}, $new_client if !$found;
  validate_doc($doc);
  write_doc($file, $doc);
  exit 0;
}

if ($cmd eq 'delete') {
  my ($file, $name) = @ARGV;
  my $doc = read_doc($file);
  @{$doc->{clients}} = grep { $_->{name} ne $name } @{$doc->{clients}};
  validate_doc($doc);
  write_doc($file, $doc);
  exit 0;
}

if ($cmd eq 'get') {
  my ($file, $name) = @ARGV;
  my $doc = read_doc($file);
  validate_doc($doc);
  for my $client (@{$doc->{clients}}) {
    next if $client->{name} ne $name;
    print join("\t",
      $client->{name},
      $client->{profile_name},
      $client->{vpn_ip},
      $client->{socks}{tag},
      $client->{socks}{server},
      $client->{socks}{port},
      $client->{socks}{username},
      $client->{socks}{password},
      $client->{socks}{network},
      $client->{unmatched_policy},
      $client->{generate_client} ? 'true' : 'false',
      $client->{remote_host},
      $client->{remote_port}
    ), "\n";
    exit 0;
  }
  die "客户端不存在: $name\n";
}

if ($cmd eq 'list') {
  my ($file) = @ARGV;
  my $doc = read_doc($file);
  validate_doc($doc);
  for my $client (@{$doc->{clients}}) {
    print join("\t",
      $client->{name},
      $client->{profile_name},
      $client->{vpn_ip},
      $client->{socks}{tag},
      $client->{socks}{server},
      $client->{socks}{port},
      $client->{socks}{network},
      $client->{unmatched_policy}
    ), "\n";
  }
  exit 0;
}

if ($cmd eq 'client-lines') {
  my ($file, $default_host, $default_port) = @ARGV;
  my $doc = read_doc($file);
  validate_doc($doc);
  for my $client (@{$doc->{clients}}) {
    next if !$client->{generate_client};
    my $remote_host = $client->{remote_host} || $default_host;
    my $remote_port = $client->{remote_port} || $default_port;
    my $ccd = "ifconfig-push $client->{vpn_ip} 255.255.255.0";
    print join("\t", $client->{name}, $remote_host, $remote_port, $ccd, $client->{profile_name}), "\n";
  }
  exit 0;
}

if ($cmd eq 'render') {
  my ($file, $singbox_file, $ccd_dir, $managed_file, $dashboard, $api_addr, $api_secret, $tproxy_port, $unmatched_policy) = @ARGV;
  $unmatched_policy = 'block' if !defined($unmatched_policy) || $unmatched_policy eq '';
  die "未匹配客户端策略只能是 block 或 direct\n" if $unmatched_policy !~ /\A(?:block|direct)\z/;
  my $doc = read_doc($file);
  validate_doc($doc);
  make_path($ccd_dir);
  make_path(dirname($singbox_file));

  my %current = map { $_->{name} => 1 } @{$doc->{clients}};
  if (-e $managed_file) {
    open my $mf, '<', $managed_file or die "无法读取 $managed_file: $!\n";
    while (my $old = <$mf>) {
      chomp $old;
      unlink "$ccd_dir/$old" if $old ne '' && !$current{$old};
    }
    close $mf;
  }

  open my $mf, '>', $managed_file or die "无法写入 $managed_file: $!\n";
  for my $client (@{$doc->{clients}}) {
    print {$mf} "$client->{name}\n";
    open my $cf, '>', "$ccd_dir/$client->{name}" or die "无法写入 CCD: $!\n";
    print {$cf} "ifconfig-push $client->{vpn_ip} 255.255.255.0\n";
    close $cf;
  }
  close $mf;

  my @outbounds = (
    { type => 'block', tag => 'block' },
    { type => 'direct', tag => 'direct' },
  );
  my @rules;
  for my $client (@{$doc->{clients}}) {
    my $socks = $client->{socks};
    my $client_unmatched_policy = $client->{unmatched_policy};
    $client_unmatched_policy = $unmatched_policy if $client_unmatched_policy eq 'inherit';
    my %outbound = (
      type => 'socks',
      tag => $socks->{tag},
      server => $socks->{server},
      server_port => int($socks->{port}),
      version => '5',
    );
    $outbound{username} = $socks->{username} if $socks->{username} ne '';
    $outbound{password} = $socks->{password} if $socks->{password} ne '';
    $outbound{network} = 'tcp' if $socks->{network} eq 'tcp_only';
    $outbound{udp_over_tcp} = { enabled => JSON::PP::true, version => 2 } if $socks->{network} eq 'udp_over_tcp';
    push @outbounds, \%outbound;

    if ($socks->{network} eq 'tcp_only') {
      push @rules, { source_ip_cidr => ["$client->{vpn_ip}/32"], port => 53, network => ['udp', 'tcp'], action => 'hijack-dns' };
      push @rules, { source_ip_cidr => ["$client->{vpn_ip}/32"], network => ['tcp'], action => 'route', outbound => $socks->{tag} };
      push @rules, { source_ip_cidr => ["$client->{vpn_ip}/32"], network => ['udp'], action => 'route', outbound => $client_unmatched_policy };
    } else {
      push @rules, { source_ip_cidr => ["$client->{vpn_ip}/32"], action => 'route', outbound => $socks->{tag} };
    }
  }

  my %config = (
    dns => {
      servers => [
        { tag => 'dns-direct', address => 'tls://8.8.8.8', detour => 'direct' }
      ],
      final => 'dns-direct',
    },
    log => { level => 'info', timestamp => JSON::PP::true },
    inbounds => [
      { type => 'tproxy', tag => 'ovpn-tproxy', listen => '0.0.0.0', listen_port => int($tproxy_port) }
    ],
    outbounds => \@outbounds,
    route => { rules => \@rules, final => $unmatched_policy },
  );

  if ($dashboard eq 'true') {
    $config{experimental} = {
      clash_api => {
        external_controller => $api_addr,
        external_ui => 'dashboard',
        external_ui_download_url => 'https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip',
        external_ui_download_detour => 'direct',
        secret => $api_secret,
      }
    };
  }

  write_doc($singbox_file, \%config);
  exit 0;
}

die "未知 proxy_json_tool 命令: $cmd\n";
PERL
}

ensure_proxy_clients_file() {
  if [[ "$OVPN_ENABLE_PROXY" != "true" ]]; then
    return
  fi

  mkdir -p "$OVPN_INSTALL_DIR"
  if [[ -n "$OVPN_PROXY_CLIENTS_JSON" && "${OVPN_PROXY_CLIENTS_JSON_APPLIED:-false}" != "true" ]]; then
    proxy_json_tool write-json "$OVPN_PROXY_CLIENTS_FILE" "$OVPN_PROXY_CLIENTS_JSON"
    OVPN_PROXY_CLIENTS_JSON_APPLIED="true"
  else
    proxy_json_tool ensure "$OVPN_PROXY_CLIENTS_FILE"
  fi
}

validate_proxy_config() {
  if [[ "$OVPN_ENABLE_PROXY" != "true" ]]; then
    return
  fi

  validate_name "sing-box 容器名称" "$SING_BOX_CONTAINER_NAME"
  validate_port "sing-box TProxy 端口" "$SING_BOX_TPROXY_PORT"
  validate_port "sing-box Dashboard 端口" "$(addr_port "$SING_BOX_API_ADDR")"
  [[ "$OVPN_PROXY_UNMATCHED_POLICY" =~ ^(block|direct)$ ]] || die "未匹配客户端策略只能是 block 或 direct。"
  [[ "$SING_BOX_IMAGE" != *".."* && "$SING_BOX_IMAGE" != *[[:space:]]* ]] || die "sing-box 镜像名称不合法。"
  command -v perl >/dev/null 2>&1 || die "后置代理 JSON 处理需要 perl，请先安装 perl。"
  ensure_proxy_clients_file
  proxy_json_tool list "$OVPN_PROXY_CLIENTS_FILE" >/dev/null
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

  validate_proxy_config

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

print_main_menu() {
  cat <<EOF

OpenVPN 落地机一键配置脚本 v$VERSION

当前安装目录: $OVPN_INSTALL_DIR
OpenVPN 镜像: $OVPN_IMAGE
OpenVPN 入口: $OVPN_SERVER_HOST:$OVPN_PORT/tcp
后置 SOCKS5 分流: $OVPN_ENABLE_PROXY

1. OpenVPN 基础配置
2. 客户端/SOCKS5 映射管理
3. 从 JSON 导入映射
4. 导出/查看当前 JSON
5. Dashboard 配置
6. 预览配置
7. 部署/更新现有服务
0. 退出
EOF
}

prepare_proxy_clients_for_menu() {
  OVPN_ENABLE_PROXY="true"
  OVPN_PROXY_CLIENTS_FILE="${OVPN_PROXY_CLIENTS_FILE:-$OVPN_INSTALL_DIR/proxy-clients.json}"
  ensure_proxy_clients_file
}

prompt_after_menu_action() {
  local choice

  MENU_NAV="stay"
  cat <<'EOF'

下一步:
1. 留在当前菜单
8. 返回上一级
9. 返回主菜单
0. 退出
EOF
  read -r -p "请选择 [1/8/9/0]: " choice
  case "${choice:-1}" in
    1) MENU_NAV="stay" ;;
    8) MENU_NAV="back" ;;
    9) MENU_NAV="main" ;;
    0) exit 0 ;;
    *)
      warn "无效选项: $choice，已留在当前菜单。"
      MENU_NAV="stay"
      ;;
  esac
}

handle_main_action_navigation() {
  prompt_after_menu_action
  case "$MENU_NAV" in
    stay|back|main) return 0 ;;
    *) return 0 ;;
  esac
}

show_proxy_clients_json() {
  prepare_proxy_clients_for_menu

  printf '\n当前 JSON 文件: %s\n\n' "$OVPN_PROXY_CLIENTS_FILE"
  cat "$OVPN_PROXY_CLIENTS_FILE"
  printf '\n'

  if proxy_json_tool list "$OVPN_PROXY_CLIENTS_FILE" | grep -q .; then
    printf '\n当前映射列表:\n'
    proxy_json_tool list "$OVPN_PROXY_CLIENTS_FILE"
  else
    printf '\n当前没有客户端/SOCKS5 映射。\n'
  fi
}

prompt_proxy_client_fields() {
  local editable_name="$1"
  local default_name="$2"
  local default_profile_name="$3"
  local default_vpn_ip="$4"
  local default_tag="$5"
  local default_server="$6"
  local default_port="$7"
  local default_username="$8"
  local default_password="$9"
  local default_network="${10}"
  local default_unmatched_policy="${11}"
  local default_generate="${12}"
  local default_remote_host="${13}"
  local default_remote_port="${14}"

  if [[ "$editable_name" == "true" ]]; then
    PROXY_CLIENT_NAME="$(prompt_text "客户端名称" "$default_name")"
  else
    PROXY_CLIENT_NAME="$default_name"
    printf '客户端名称 [%s]\n' "$PROXY_CLIENT_NAME"
  fi

  if [[ -z "$default_profile_name" ]]; then
    default_profile_name="$PROXY_CLIENT_NAME"
  fi
  PROXY_CLIENT_PROFILE_NAME="$(prompt_text "OpenVPN Connect Profile Name（导入后显示名）" "$default_profile_name")"
  PROXY_CLIENT_VPN_IP="$(prompt_text "固定 VPN IP" "$default_vpn_ip")"
  PROXY_CLIENT_SOCKS_TAG="$(prompt_text "SOCKS tag" "$default_tag")"
  PROXY_CLIENT_SOCKS_SERVER="$(prompt_text "SOCKS 地址" "$default_server")"
  PROXY_CLIENT_SOCKS_PORT="$(prompt_text "SOCKS 端口" "$default_port")"
  PROXY_CLIENT_SOCKS_USERNAME="$(prompt_text "SOCKS 用户名，可空" "$default_username")"
  PROXY_CLIENT_SOCKS_PASSWORD="$(prompt_text "SOCKS 密码，可空" "$default_password")"
  PROXY_CLIENT_SOCKS_NETWORK="$(prompt_text "SOCKS UDP 能力 tcp_udp/tcp_only/udp_over_tcp，普通 SOCKS 出现 code=9 请选 tcp_only" "$default_network")"
  PROXY_CLIENT_UNMATCHED_POLICY="$(prompt_text "本客户端未命中策略 inherit/block/direct" "$default_unmatched_policy")"
  PROXY_CLIENT_GENERATE="$(prompt_bool "是否生成客户端 .ovpn" "$default_generate")"

  if [[ "$PROXY_CLIENT_GENERATE" == "true" ]]; then
    PROXY_CLIENT_REMOTE_HOST="$(prompt_text "客户端 remote 主机" "$default_remote_host")"
    PROXY_CLIENT_REMOTE_PORT="$(prompt_text "客户端 remote 端口" "$default_remote_port")"
  else
    PROXY_CLIENT_REMOTE_HOST=""
    PROXY_CLIENT_REMOTE_PORT=""
  fi
}

add_proxy_mapping() {
  prepare_proxy_clients_for_menu
  prompt_proxy_client_fields \
    "true" \
    "client1" \
    "client1" \
    "10.8.0.10" \
    "socks-client1" \
    "127.0.0.1" \
    "1080" \
    "" \
    "" \
    "tcp_udp" \
    "inherit" \
    "true" \
    "$OVPN_SERVER_HOST" \
    "$OVPN_PORT"

  proxy_json_tool add \
    "$OVPN_PROXY_CLIENTS_FILE" \
    "$PROXY_CLIENT_NAME" \
    "$PROXY_CLIENT_PROFILE_NAME" \
    "$PROXY_CLIENT_VPN_IP" \
    "$PROXY_CLIENT_SOCKS_TAG" \
    "$PROXY_CLIENT_SOCKS_SERVER" \
    "$PROXY_CLIENT_SOCKS_PORT" \
    "$PROXY_CLIENT_SOCKS_USERNAME" \
    "$PROXY_CLIENT_SOCKS_PASSWORD" \
    "$PROXY_CLIENT_SOCKS_NETWORK" \
    "$PROXY_CLIENT_UNMATCHED_POLICY" \
    "$PROXY_CLIENT_GENERATE" \
    "$PROXY_CLIENT_REMOTE_HOST" \
    "$PROXY_CLIENT_REMOTE_PORT"
  log "已添加映射，请最后选择“部署/更新现有服务”统一应用。"
}

select_proxy_client_name() {
  local prompt="$1"
  local choice
  local index
  local line
  local name profile_name vpn_ip tag server port network unmatched_policy
  local -a lines

  mapfile -t lines < <(proxy_json_tool list "$OVPN_PROXY_CLIENTS_FILE")
  ((${#lines[@]} > 0)) || die "当前没有可选择的客户端映射。"

  printf '\n已有映射:\n'
  for index in "${!lines[@]}"; do
    line="${lines[$index]}"
    IFS=$'\t' read -r name profile_name vpn_ip tag server port network unmatched_policy <<<"$line"
    printf '  %d. %s  Profile="%s"  VPN=%s  SOCKS=%s(%s:%s)  network=%s  unmatched=%s\n' \
      "$((index + 1))" "$name" "$profile_name" "$vpn_ip" "$tag" "$server" "$port" "$network" "$unmatched_policy"
  done

  read -r -p "$prompt [1-${#lines[@]}]: " choice
  [[ -n "$choice" ]] || die "客户端选择不能为空。"

  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    (( choice >= 1 && choice <= ${#lines[@]} )) || die "客户端编号超出范围。"
    line="${lines[$((choice - 1))]}"
    IFS=$'\t' read -r SELECTED_PROXY_CLIENT_NAME _ <<<"$line"
  else
    SELECTED_PROXY_CLIENT_NAME="$choice"
  fi
}

edit_proxy_mapping() {
  local name
  local current
  local current_name current_profile_name current_vpn_ip current_tag current_server current_port
  local current_username current_password current_network current_unmatched_policy current_generate
  local current_remote_host current_remote_port

  prepare_proxy_clients_for_menu
  select_proxy_client_name "请选择要修改的客户端编号或名称"
  name="$SELECTED_PROXY_CLIENT_NAME"

  current="$(proxy_json_tool get "$OVPN_PROXY_CLIENTS_FILE" "$name")"
  IFS=$'\t' read -r \
    current_name \
    current_profile_name \
    current_vpn_ip \
    current_tag \
    current_server \
    current_port \
    current_username \
    current_password \
    current_network \
    current_unmatched_policy \
    current_generate \
    current_remote_host \
    current_remote_port <<<"$current"

  prompt_proxy_client_fields \
    "false" \
    "$current_name" \
    "$current_profile_name" \
    "$current_vpn_ip" \
    "$current_tag" \
    "$current_server" \
    "$current_port" \
    "$current_username" \
    "$current_password" \
    "$current_network" \
    "$current_unmatched_policy" \
    "$current_generate" \
    "${current_remote_host:-$OVPN_SERVER_HOST}" \
    "${current_remote_port:-$OVPN_PORT}"

  proxy_json_tool edit \
    "$OVPN_PROXY_CLIENTS_FILE" \
    "$PROXY_CLIENT_NAME" \
    "$PROXY_CLIENT_PROFILE_NAME" \
    "$PROXY_CLIENT_VPN_IP" \
    "$PROXY_CLIENT_SOCKS_TAG" \
    "$PROXY_CLIENT_SOCKS_SERVER" \
    "$PROXY_CLIENT_SOCKS_PORT" \
    "$PROXY_CLIENT_SOCKS_USERNAME" \
    "$PROXY_CLIENT_SOCKS_PASSWORD" \
    "$PROXY_CLIENT_SOCKS_NETWORK" \
    "$PROXY_CLIENT_UNMATCHED_POLICY" \
    "$PROXY_CLIENT_GENERATE" \
    "$PROXY_CLIENT_REMOTE_HOST" \
    "$PROXY_CLIENT_REMOTE_PORT"
  log "已修改映射，请最后选择“部署/更新现有服务”统一应用。"
}

delete_proxy_mapping() {
  local name

  prepare_proxy_clients_for_menu
  select_proxy_client_name "请选择要删除的客户端编号或名称"
  name="$SELECTED_PROXY_CLIENT_NAME"

  proxy_json_tool delete "$OVPN_PROXY_CLIENTS_FILE" "$name"
  rm -f "$OVPN_INSTALL_DIR/data/ccd/$name"
  log "已删除映射和 CCD: $name"
  warn "不会吊销证书，也不会删除已有 .ovpn；如需吊销证书，请在 Web 面板单独处理。"
}

configure_unmatched_policy() {
  local value

  value="$(prompt_text "未匹配客户端策略 block/direct" "$OVPN_PROXY_UNMATCHED_POLICY")"
  [[ "$value" =~ ^(block|direct)$ ]] || die "未匹配客户端策略只能是 block 或 direct。"
  OVPN_PROXY_UNMATCHED_POLICY="$value"

  if [[ "$OVPN_PROXY_UNMATCHED_POLICY" == "direct" ]]; then
    warn "未匹配客户端将直接走落地机公网出口，不再阻断。"
  else
    log "未匹配客户端将继续阻断。"
  fi
}

manage_proxy_clients_menu() {
  local choice

  while true; do
    cat <<'EOF'

客户端/SOCKS5 映射管理

1. 查看映射
2. 添加映射
3. 修改映射
4. 删除映射
5. 未匹配客户端策略
8. 返回上一级
9. 返回主菜单
0. 退出
EOF
    read -r -p "请选择 [1-5/8/9/0]: " choice
    case "$choice" in
      1)
        show_proxy_clients_json
        prompt_after_menu_action
        ;;
      2)
        add_proxy_mapping
        prompt_after_menu_action
        ;;
      3)
        edit_proxy_mapping
        prompt_after_menu_action
        ;;
      4)
        delete_proxy_mapping
        prompt_after_menu_action
        ;;
      5)
        configure_unmatched_policy
        prompt_after_menu_action
        ;;
      8|9) return ;;
      0) exit 0 ;;
      *) warn "无效选项: $choice" ;;
    esac

    case "${MENU_NAV:-stay}" in
      back|main) return ;;
    esac
  done
}

import_proxy_clients_menu() {
  local source_json

  prepare_proxy_clients_for_menu
  source_json="$(prompt_text "要导入的 JSON 文件路径" "$OVPN_PROXY_CLIENTS_FILE")"
  [[ -f "$source_json" ]] || die "JSON 文件不存在: $source_json"
  proxy_json_tool import "$OVPN_PROXY_CLIENTS_FILE" "$source_json"
  log "已导入映射到: $OVPN_PROXY_CLIENTS_FILE"
}

configure_dashboard_menu() {
  local current_port

  OVPN_PROXY_DASHBOARD="$(prompt_bool "是否启用 sing-box Dashboard" "$OVPN_PROXY_DASHBOARD")"
  if [[ "$OVPN_PROXY_DASHBOARD" == "true" ]]; then
    current_port="$(addr_port "$SING_BOX_API_ADDR")"
    SING_BOX_DASHBOARD_PUBLIC="$(prompt_bool "是否允许公网直接访问 Dashboard" "$SING_BOX_DASHBOARD_PUBLIC")"
    if [[ "$SING_BOX_DASHBOARD_PUBLIC" == "true" && "$SING_BOX_API_ADDR" == 127.0.0.1:* ]]; then
      SING_BOX_API_ADDR="0.0.0.0:$current_port"
    elif [[ "$SING_BOX_DASHBOARD_PUBLIC" != "true" && "$SING_BOX_API_ADDR" == 0.0.0.0:* ]]; then
      SING_BOX_API_ADDR="127.0.0.1:$current_port"
    fi
    SING_BOX_API_ADDR="$(prompt_text "Dashboard 监听地址" "$SING_BOX_API_ADDR")"
    SING_BOX_API_SECRET="$(prompt_text "Dashboard secret" "$SING_BOX_API_SECRET")"
  fi
  if [[ "$OVPN_PROXY_DASHBOARD" == "true" && "$SING_BOX_DASHBOARD_PUBLIC" == "true" ]]; then
    warn "Dashboard 将允许公网访问，请确认已设置强 secret，并优先用防火墙限制来源 IP。"
  fi
  log "Dashboard 配置已更新。网页路径是 /ui/，不是根路径 /。"
}

preview_configuration() {
  validate_config
  render_files
  log "已预览生成配置到: $OVPN_INSTALL_DIR"
  if [[ "$OVPN_ENABLE_PROXY" == "true" ]]; then
    log "后置代理 JSON: $OVPN_PROXY_CLIENTS_FILE"
    log "sing-box 配置: $OVPN_INSTALL_DIR/sing-box/config.json"
    log "TProxy 规则: $OVPN_INSTALL_DIR/apply-tproxy-rules.sh"
  fi
}

run_menu() {
  local choice

  collect_from_env

  while true; do
    print_main_menu
    read -r -p "请选择 [0-7]: " choice
    case "$choice" in
      1)
        collect_interactive
        OVPN_PROXY_CLIENTS_FILE="$OVPN_INSTALL_DIR/proxy-clients.json"
        handle_main_action_navigation
        ;;
      2)
        manage_proxy_clients_menu
        ;;
      3)
        import_proxy_clients_menu
        handle_main_action_navigation
        ;;
      4)
        show_proxy_clients_json
        handle_main_action_navigation
        ;;
      5)
        configure_dashboard_menu
        handle_main_action_navigation
        ;;
      6)
        preview_configuration
        handle_main_action_navigation
        ;;
      7)
        validate_config
        deploy
        ;;
      0)
        exit 0
        ;;
      *)
        warn "无效选项: $choice"
        ;;
    esac
  done
}

render_compose() {
  local compose_file="$OVPN_INSTALL_DIR/docker-compose.yml"

  if [[ "$OVPN_ENABLE_PROXY" == "true" ]]; then
    cat >"$compose_file" <<EOF
services:
  openvpn:
    image: $OVPN_IMAGE
    container_name: $OVPN_CONTAINER_NAME
    network_mode: host
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./data:/data
      - /etc/localtime:/etc/localtime:ro
    restart: unless-stopped

  sing-box:
    image: $SING_BOX_IMAGE
    container_name: $SING_BOX_CONTAINER_NAME
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - ./sing-box:/etc/sing-box
    command: -D /var/lib/sing-box -C /etc/sing-box run
    restart: unless-stopped
EOF
    return
  fi

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
  local container_web_port="8833"

  if [[ "$OVPN_ENABLE_PROXY" == "true" ]]; then
    container_web_port="$OVPN_WEB_PORT"
  fi

  cat >"$config_file" <<EOF
{
  "system": {
    "base": {
      "site_url": "http://$OVPN_SERVER_HOST:$OVPN_WEB_PORT",
      "web_port": "$container_web_port",
      "server_cn": "$OVPN_SERVER_CN",
      "server_name": "$OVPN_SERVER_NAME",
      "auto_update_ovpn_config": false,
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
OVPN_ENABLE_PROXY=$OVPN_ENABLE_PROXY
OVPN_PROXY_CLIENTS_FILE=$OVPN_PROXY_CLIENTS_FILE
OVPN_PROXY_UNMATCHED_POLICY=$OVPN_PROXY_UNMATCHED_POLICY
OVPN_PROXY_DASHBOARD=$OVPN_PROXY_DASHBOARD
SING_BOX_IMAGE=$SING_BOX_IMAGE
SING_BOX_CONTAINER_NAME=$SING_BOX_CONTAINER_NAME
SING_BOX_DASHBOARD_PUBLIC=$SING_BOX_DASHBOARD_PUBLIC
SING_BOX_TPROXY_PORT=$SING_BOX_TPROXY_PORT
SING_BOX_API_ADDR=$SING_BOX_API_ADDR
SING_BOX_API_SECRET=$SING_BOX_API_SECRET
EOF
  chmod 600 "$env_file"
}

render_tproxy_rules() {
  local rules_file="$OVPN_INSTALL_DIR/apply-tproxy-rules.sh"
  local service_dir="$OVPN_INSTALL_DIR/systemd"
  local service_file="$service_dir/openvpn-tproxy-rules.service"

  cat >"$rules_file" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

IPT="\${IPT:-iptables}"
CHAIN="OVPN_SINGBOX_TPROXY"
TPROXY_PORT="$SING_BOX_TPROXY_PORT"
VPN_CIDR="10.8.0.0/24"

ip rule add fwmark 1 table 100 2>/dev/null || true
ip route replace local default dev lo table 100

\$IPT -t mangle -N "\$CHAIN" 2>/dev/null || true
\$IPT -t mangle -F "\$CHAIN"
\$IPT -t mangle -C PREROUTING -i tun0 -s "\$VPN_CIDR" -p tcp -j "\$CHAIN" 2>/dev/null || \\
  \$IPT -t mangle -A PREROUTING -i tun0 -s "\$VPN_CIDR" -p tcp -j "\$CHAIN"
\$IPT -t mangle -C PREROUTING -i tun0 -s "\$VPN_CIDR" -p udp -j "\$CHAIN" 2>/dev/null || \\
  \$IPT -t mangle -A PREROUTING -i tun0 -s "\$VPN_CIDR" -p udp -j "\$CHAIN"

\$IPT -t mangle -A "\$CHAIN" -p tcp -j TPROXY --on-port "\$TPROXY_PORT" --tproxy-mark 1
\$IPT -t mangle -A "\$CHAIN" -p udp -j TPROXY --on-port "\$TPROXY_PORT" --tproxy-mark 1
EOF
  chmod +x "$rules_file"

  mkdir -p "$service_dir"
  cat >"$service_file" <<EOF
[Unit]
Description=Apply OpenVPN sing-box TProxy rules
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$rules_file
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

render_proxy_files() {
  if [[ "$OVPN_ENABLE_PROXY" != "true" ]]; then
    return
  fi

  ensure_proxy_clients_file
  proxy_json_tool render \
    "$OVPN_PROXY_CLIENTS_FILE" \
    "$OVPN_INSTALL_DIR/sing-box/config.json" \
    "$OVPN_INSTALL_DIR/data/ccd" \
    "$OVPN_INSTALL_DIR/data/.proxy-managed-clients" \
    "$OVPN_PROXY_DASHBOARD" \
    "$SING_BOX_API_ADDR" \
    "$SING_BOX_API_SECRET" \
    "$SING_BOX_TPROXY_PORT" \
    "$OVPN_PROXY_UNMATCHED_POLICY"
  render_tproxy_rules
}

render_files() {
  mkdir -p "$OVPN_INSTALL_DIR/data"
  render_compose
  if [[ ! -f "$OVPN_INSTALL_DIR/data/server.conf" ]]; then
    render_config_json
  else
    log "检测到已有 server.conf，保留现有 OpenVPN 证书和服务端配置。"
  fi
  render_env_summary
  render_proxy_files
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
    log "检测到已有 $data_dir/server.conf，将按更新现有部署处理，不重置证书。"
    return
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

  if [[ "$OVPN_ENABLE_PROXY" == "true" ]]; then
    log "正在下载 sing-box 镜像: $SING_BOX_IMAGE"
    docker pull "$SING_BOX_IMAGE"
  fi
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
  local client_name="${1:-$OVPN_CLIENT_NAME}"
  local profile_name="${2:-}"
  local client_file="$OVPN_INSTALL_DIR/data/clients/$client_name.ovpn"

  if [[ ! -f "$client_file" ]]; then
    warn "未找到客户端配置文件，无法修正客户端协议或 Profile Name: $client_file"
    return 1
  fi

  if grep -q '^proto tcp-server$' "$client_file"; then
    sed -i 's/^proto tcp-server$/proto tcp-client/' "$client_file"
    log "已将客户端配置协议修正为 tcp-client: $client_file"
  fi

  if [[ -n "$profile_name" ]]; then
    PROFILE_NAME="$profile_name" perl -0pi -e '
      my $name = $ENV{"PROFILE_NAME"} // "";
      $name =~ s/\\/\\\\/g;
      $name =~ s/"/\\"/g;
      my $line = "setenv FRIENDLY_NAME \"$name\"\n";
      s/^setenv FRIENDLY_NAME .*\n//mg;
      if (/\Aclient\n/) {
        s/\Aclient\n/client\n$line/;
      } else {
        $_ = $line . $_;
      }
    ' "$client_file"
    log "已设置 OpenVPN Connect Profile Name: $profile_name"
  fi
}

install_tproxy_service() {
  if [[ "$OVPN_ENABLE_PROXY" != "true" ]]; then
    return
  fi

  if command -v systemctl >/dev/null 2>&1; then
    cp "$OVPN_INSTALL_DIR/systemd/openvpn-tproxy-rules.service" /etc/systemd/system/openvpn-tproxy-rules.service
    systemctl daemon-reload
    systemctl enable --now openvpn-tproxy-rules.service >/dev/null
    log "TProxy 规则 systemd 服务已启用: openvpn-tproxy-rules.service"
  else
    "$OVPN_INSTALL_DIR/apply-tproxy-rules.sh"
    warn "未检测到 systemd，已直接应用 TProxy 规则；重启后需要重新执行 apply-tproxy-rules.sh。"
  fi
}

create_proxy_clients() {
  local name
  local remote_host
  local remote_port
  local ccd
  local profile_name

  if [[ "$OVPN_ENABLE_PROXY" != "true" ]]; then
    return
  fi

  while IFS=$'\t' read -r name remote_host remote_port ccd profile_name; do
    [[ -n "$name" ]] || continue
    if docker exec "$OVPN_CONTAINER_NAME" /usr/bin/docker-entrypoint.sh \
      genclient "$name" "$remote_host" "$remote_port" "" "$ccd" "false" >/dev/null; then
      normalize_client_profile_proto "$name" "$profile_name" || true
      log "已生成代理分流客户端: $name -> $remote_host:$remote_port / $ccd"
    else
      warn "生成代理分流客户端失败: $name"
    fi
  done < <(proxy_json_tool client-lines "$OVPN_PROXY_CLIENTS_FILE" "$OVPN_SERVER_HOST" "$OVPN_PORT")
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
  local dashboard_summary
  local dashboard_port
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
    create_proxy_clients
  else
    warn "OpenVPN 初始化文件在等待时间内未生成，已跳过认证设置、网关修正和客户端生成。"
    warn "请检查: docker logs $OVPN_CONTAINER_NAME"
  fi

  install_tproxy_service

  log "正在重启容器，让配置完全生效..."
  docker restart "$OVPN_CONTAINER_NAME" >/dev/null
  if [[ "$OVPN_ENABLE_PROXY" == "true" ]]; then
    docker restart "$SING_BOX_CONTAINER_NAME" >/dev/null || warn "sing-box 容器重启失败，请检查: docker logs $SING_BOX_CONTAINER_NAME"
  fi

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

  dashboard_port="$(addr_port "$SING_BOX_API_ADDR")"
  if [[ "$OVPN_ENABLE_PROXY" == "true" && "$OVPN_PROXY_DASHBOARD" == "true" && "$SING_BOX_DASHBOARD_PUBLIC" == "true" ]]; then
    dashboard_summary="sing-box Dashboard:
  未匹配客户端策略: $OVPN_PROXY_UNMATCHED_POLICY
  服务器监听: $SING_BOX_API_ADDR
  公网访问地址: http://$OVPN_SERVER_HOST:$dashboard_port/ui/
  Secret: $SING_BOX_API_SECRET
  安全提醒: 9090 是控制 API 和 Dashboard，请设置强 secret，并优先用防火墙限制来源 IP。"
  elif [[ "$OVPN_ENABLE_PROXY" == "true" && "$OVPN_PROXY_DASHBOARD" == "true" ]]; then
    dashboard_summary="sing-box Dashboard:
  未匹配客户端策略: $OVPN_PROXY_UNMATCHED_POLICY
  服务器仅监听: $SING_BOX_API_ADDR
  本地访问地址: http://127.0.0.1:9090/ui/
  Secret: $SING_BOX_API_SECRET
  注意: 当前未启用公网访问；如需公网直连，请在 Dashboard 配置里启用。"
  elif [[ "$OVPN_ENABLE_PROXY" == "true" ]]; then
    dashboard_summary="sing-box Dashboard:
  未匹配客户端策略: $OVPN_PROXY_UNMATCHED_POLICY
  未启用"
  else
    dashboard_summary=""
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

$dashboard_summary

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
    --legacy-interactive)
      collect_from_env
      collect_interactive
      ;;
    --render-only)
      RENDER_ONLY=true
      OVPN_INSTALL_DIR="${2:-${OVPN_INSTALL_DIR:-}}"
      [[ -n "$OVPN_INSTALL_DIR" ]] || die "--render-only 需要指定输出目录。"
      collect_from_env
      ;;
    "")
      run_menu
      exit 0
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
