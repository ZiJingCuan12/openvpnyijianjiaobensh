#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/opt/zeek/logs/current/conn.log"
LOCAL_IP=""
PORT_MIN=2000
PORT_MAX=65535
FORMAT="table"
TAIL_LINES=0
INCLUDE_NOISE=false
SUSPECT_MIN_SECONDS=30
SUSPECT_MIN_BYTES=1048576
NOISE_MAX_SECONDS=10
NOISE_MAX_BYTES=65536

usage() {
  cat <<'EOF'
Zeek OpenVPN 入口端口报表脚本

用法:
  bash zeek-openvpn-report.sh [选项]

常用选项:
  --log PATH                 Zeek conn.log 路径，默认 /opt/zeek/logs/current/conn.log
  --local-ip IP              入口机本机 IP；不填则尝试自动探测，填 all 则不过滤本机 IP
  --ports MIN-MAX            客户入口端口范围，默认 2000-65535
  --tail N                   只读取最后 N 行；默认 0 表示读取整个文件
  --format table|csv|json    输出格式，默认 table
  --include-noise            显示短失败连接/扫描噪音
  --suspect-seconds N        非 OpenVPN 可疑连接最小时长，默认 30
  --suspect-bytes N          非 OpenVPN 可疑连接最小总字节数，默认 1048576
  -h, --help                 显示帮助

状态说明:
  OK_OPENVPN      service 包含 spicy_openvpn，符合 OpenVPN 白名单
  SUSPECT         超过时长和流量阈值，但未识别为 OpenVPN
  CHECK           非 OpenVPN，且未达到 SUSPECT 阈值
  IGNORED_NOISE   短失败连接/扫描噪音，默认隐藏
EOF
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

detect_local_ip() {
  ip -4 route get 8.8.8.8 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

parse_ports() {
  local ports="$1"

  [[ "$ports" =~ ^[0-9]+-[0-9]+$ ]] || die "--ports 格式必须是 MIN-MAX，例如 2000-65535"
  PORT_MIN="${ports%-*}"
  PORT_MAX="${ports#*-}"
  (( PORT_MIN >= 1 && PORT_MIN <= PORT_MAX && PORT_MAX <= 65535 )) || die "--ports 范围必须在 1-65535 之间"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log)
        LOG_FILE="${2:-}"
        shift 2
        ;;
      --local-ip)
        LOCAL_IP="${2:-}"
        shift 2
        ;;
      --ports)
        parse_ports "${2:-}"
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
        [[ "$SUSPECT_MIN_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--suspect-seconds 必须是数字"
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

run_report() {
  [[ -f "$LOG_FILE" ]] || die "日志文件不存在: $LOG_FILE"
  require_cmd perl

  ZEEK_REPORT_LOG_FILE="$LOG_FILE" \
  ZEEK_REPORT_LOCAL_IP="$LOCAL_IP" \
  ZEEK_REPORT_PORT_MIN="$PORT_MIN" \
  ZEEK_REPORT_PORT_MAX="$PORT_MAX" \
  ZEEK_REPORT_FORMAT="$FORMAT" \
  ZEEK_REPORT_TAIL_LINES="$TAIL_LINES" \
  ZEEK_REPORT_INCLUDE_NOISE="$INCLUDE_NOISE" \
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

if ($format eq 'json') {
  print $json->pretty->encode(\@rows);
  exit 0;
}

if ($format eq 'csv') {
  print join(',', map { csv_escape($_) } @fields), "\n";
  for my $row (@rows) {
    print join(',', map { csv_escape($row->{$_}) } @fields), "\n";
  }
  exit 0;
}

my @headers = qw(STATUS CLIENT_IP PORT PROTO SERVICE CONNS DURATION_S ORIG_BYTES RESP_BYTES TOTAL_BYTES LAST_SEEN STATES);
my @table_rows = (
  \@headers,
  map {
    [
      $_->{status},
      $_->{client_ip},
      $_->{port},
      $_->{proto},
      $_->{service},
      $_->{connections},
      $_->{duration_s},
      $_->{orig_bytes},
      $_->{resp_bytes},
      $_->{total_bytes},
      $_->{last_seen},
      $_->{states},
    ]
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

main() {
  parse_args "$@"

  if [[ -z "$LOCAL_IP" ]]; then
    LOCAL_IP="$(detect_local_ip || true)"
  elif [[ "$LOCAL_IP" == "all" ]]; then
    LOCAL_IP=""
  fi

  run_report
}

main "$@"
