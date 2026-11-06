#!/bin/sh
set -eu
umask 077
[ "$(id -u)" -eq 0 ] || { echo '请以 root 执行 sh install-xray-menu.sh'; exit 1; }
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  INIT=systemd; UNIT=/etc/systemd/system/xray-menu.service
elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
  INIT=openrc; UNIT=/etc/init.d/xray-menu
else
  echo '需要 systemd 或 OpenRC；不支持无 init 的普通容器。'; exit 1
fi
if [ -e /opt/xray-menu ] && [ ! -f /opt/xray-menu/.managed-by-xray-menu ]; then
  echo '/opt/xray-menu 已存在且非本工具管理，停止。'; exit 1
fi
[ ! -L /opt/xray-menu ] && [ ! -L /etc/xray-menu ] || { echo '目录为符号链接，停止。'; exit 1; }
for FILE in "$UNIT" /usr/local/bin/xray-menu; do
  [ ! -L "$FILE" ] || { echo '同名管理文件为符号链接，停止。'; exit 1; }
  if [ -e "$FILE" ] && ! grep -q '^# Managed by xray-menu$' "$FILE"; then
    echo '同名文件不属于本工具，停止以避免覆盖。'; exit 1
  fi
done
case "$(uname -m)" in
  x86_64) ARCH=64;;aarch64|arm64) ARCH=arm64-v8a;;*) echo '支持 x86_64 / arm64'; exit 1;;
esac
MISSING=
for DEP in curl jq; do command -v "$DEP" >/dev/null 2>&1 || MISSING="$MISSING $DEP"; done
if [ ! -x /opt/xray-menu/xray ]; then
  command -v unzip >/dev/null 2>&1 || MISSING="$MISSING unzip"
fi
if [ ! -s /etc/ssl/certs/ca-certificates.crt ] &&
   [ ! -s /etc/pki/tls/certs/ca-bundle.crt ] && [ ! -s /etc/ssl/ca-bundle.pem ]; then
  MISSING="$MISSING ca-certificates"
fi
if [ -n "$MISSING" ]; then
  echo "只安装缺失依赖：$MISSING"
  if command -v apk >/dev/null 2>&1; then apk add --no-cache $MISSING
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-upgrade $MISSING
  elif command -v dnf >/dev/null 2>&1; then dnf install -y $MISSING
  elif command -v yum >/dev/null 2>&1; then yum install -y $MISSING
  elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install $MISSING
  elif command -v pacman >/dev/null 2>&1; then pacman -S --needed --noconfirm $MISSING
  else echo '请手动安装缺失依赖后重试。'; exit 1; fi
else echo '依赖已满足，跳过包管理器。'; fi
for DEP in jq curl base64 od sha256sum; do
  command -v "$DEP" >/dev/null 2>&1 || { echo "缺少系统工具 $DEP"; exit 1; }
done
install -d -m 700 /opt/xray-menu /etc/xray-menu
install -d -m 755 /usr/local/bin
touch /opt/xray-menu/.managed-by-xray-menu
SESSION="/opt/xray-menu/install-$(date +%Y%m%d-%H%M%S)-$$"
install -d -m 700 "$SESSION"
if [ ! -x /opt/xray-menu/xray ]; then
  VERSION=${XRAY_VERSION:-}
  if [ -z "$VERSION" ]; then
    echo '查询 Xray 官方最新稳定版本……'
    curl -fL --retry 3 --connect-timeout 20 \
      https://api.github.com/repos/XTLS/Xray-core/releases/latest \
      -o "$SESSION/release.json"
    VERSION=$(jq -er '.tag_name | select(type=="string")' "$SESSION/release.json")
  fi
  printf '%s\n' "$VERSION" | grep -Eq '^v[0-9]+(\.[0-9]+)*$' || {
    echo 'Xray 版本号无效，请检查 XRAY_VERSION。'; exit 1;
  }
  ASSET="Xray-linux-${ARCH}.zip"
  BASE="https://github.com/XTLS/Xray-core/releases/download/${VERSION}"
  echo "下载 Xray $VERSION ($ARCH)……"
  curl -fL --retry 3 --connect-timeout 20 "$BASE/$ASSET" -o "$SESSION/core.zip"
  curl -fL --retry 3 --connect-timeout 20 "$BASE/$ASSET.dgst" -o "$SESSION/core.dgst"
  EXPECTED=$(awk '/^SHA2-256[[:space:]]*=/{print $NF}' "$SESSION/core.dgst" | tr A-F a-f)
  printf '%s\n' "$EXPECTED" | grep -Eq '^[a-f0-9]{64}$' || { echo '无效校验文件'; exit 1; }
  ACTUAL=$(sha256sum "$SESSION/core.zip" | awk '{print $1}')
  [ "$ACTUAL" = "$EXPECTED" ] || { echo 'SHA256 校验失败'; exit 1; }
  unzip -p "$SESSION/core.zip" xray > "$SESSION/xray"
  chmod 755 "$SESSION/xray"
  mv "$SESSION/xray" /opt/xray-menu/xray
  rm -f -- "$SESSION/core.zip" "$SESSION/core.dgst"
fi
if [ -f /opt/xray-menu/manager.sh ]; then cp -p /opt/xray-menu/manager.sh "$SESSION/manager.previous.sh"; fi
cat > "$SESSION/manager.sh" <<'XRAY_MENU_SHELL'
#!/bin/sh
# Managed by xray-menu
# POSIX sh + jq. Xray is the only persistent process.
set -u
umask 077
LC_ALL=C
export LC_ALL
ROOT=/etc/xray-menu
BIN=/opt/xray-menu/xray
PROG=/opt/xray-menu
SERVICE=xray-menu
WORK=
PROBE_PID=
STTY_SAVED=
LOCK_OWNED=no
say() { printf '%s\n' "$*"; }
fail() { say "操作未完成：$*" >&2; return 1; }
ask() {
  printf '%s' "$1" >&2
  [ -z "${2-}" ] || printf ' [%s]' "$2" >&2
  printf ': ' >&2
  if [ "${3-}" = secret ] && [ -t 0 ]; then STTY_SAVED=$(stty -g); stty -echo; fi
  IFS= read -r REPLY || return 1
  if [ -n "$STTY_SAVED" ]; then stty "$STTY_SAVED"; STTY_SAVED=; printf '\n' >&2; fi
  [ -n "$REPLY" ] || REPLY=${2-}
}
required() { ask "$@" && [ -n "$REPLY" ] || fail '此项不能为空'; }
yes() { ask "$1 (y/n)" n && [ "$REPLY" = y ]; }
valid_port() {
  case "$1" in ''|*[!0-9]*) return 1;; esac
  [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
valid_host() {
  [ -n "$1" ] && [ "${#1}" -le 253 ] || return 1
  case "$1" in *[!a-zA-Z0-9.:-]*|-*|.*|*.) return 1;; esac
}
valid_uuid() {
  [ "${#1}" -eq 36 ] || return 1
  case "$1" in *[!0-9a-fA-F-]*) return 1;;esac
  printf '%s\n' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}
uri() { jq -rn --arg v "$1" '$v|@uri'; }
unuri() {
  printf '%s' "$1" | awk '
  function hex(c){return index("0123456789abcdef",tolower(c))-1}
  { for(i=1;i<=length($0);i++) {
      c=substr($0,i,1)
      if(c=="%") { a=hex(substr($0,i+1,1));b=hex(substr($0,i+2,1));
        if(a<0||b<0||i+2>length($0)||a*16+b<32||a*16+b==127)exit 1;
        printf "%c",a*16+b;i+=2
      } else printf "%s",c
  }}'
}
b64d() {
  _b=$(printf '%s' "$1" | tr '_-' '/+')
  case $((${#_b} % 4)) in 2) _b="$_b==";;3) _b="$_b=";;1) return 1;;esac
  printf '%s' "$_b" | base64 -d 2>/dev/null
}
endpoint() { case "$1" in *:*) printf '[%s]:%s' "$1" "$2";;*) printf '%s:%s' "$1" "$2";;esac; }
manager() {
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then INIT=systemd
  elif command -v rc-service >/dev/null 2>&1; then INIT=openrc
  else fail '需要 systemd 或 OpenRC'; return 1; fi
}
active() { if [ "$INIT" = systemd ]; then systemctl is-active --quiet "$SERVICE"; else rc-service "$SERVICE" status >/dev/null 2>&1; fi; }
boot() { if [ "$INIT" = systemd ]; then systemctl is-enabled --quiet "$SERVICE"; else [ -L /etc/runlevels/default/xray-menu ]; fi; }
svc() {
  if [ "$INIT" = systemd ]; then systemctl "$1" "$SERVICE"; return $?; fi
  case "$1" in
    enable) boot || rc-update add "$SERVICE" default;;
    disable) if boot; then rc-update del "$SERVICE" default; fi;;
    stop) rc-service "$SERVICE" stop || { ! active; };;
    *) rc-service "$SERVICE" "$1";;
  esac
}
cleanup() {
  [ -z "$STTY_SAVED" ] || stty "$STTY_SAVED" 2>/dev/null || :
  if [ -n "$PROBE_PID" ]; then kill "$PROBE_PID" 2>/dev/null || :; wait "$PROBE_PID" 2>/dev/null || :; fi
  if [ "$WORK" = "$ROOT/.work-$$" ] && [ -d "$WORK" ] && [ ! -L "$WORK" ]; then rm -rf -- "$WORK"; fi
  if [ "$LOCK_OWNED" = yes ]; then rm -f -- "$ROOT/manager.lock.d/pid"; rmdir "$ROOT/manager.lock.d" 2>/dev/null || :; fi
}
load_state() {
  if [ -f "$ROOT/current/state.json" ]; then S=$(cat "$ROOT/current/state.json")
  else S='{"schema":1,"entries":[],"outbounds":[]}'; fi
  printf '%s' "$S" | jq -e '.schema==1 and (.entries|type=="array") and (.outbounds|type=="array")' >/dev/null || fail '配置结构异常'
}
update_s() { _new=$(printf '%s' "$S" | jq "$@") && S=$_new; }
compile_config() {
  jq '{log:{loglevel:"warning"},inbounds:[.entries[].inbound],
      outbounds:([{tag:"direct",protocol:"freedom"}]+.outbounds),
      routing:{domainStrategy:"AsIs",rules:[.entries[]|{type:"field",inboundTag:[.inbound.tag],outboundTag:.out}]}}' "$1"
}
apply_state() {
  _generation="gen-$(date +%Y%m%d-%H%M%S)-$$"
  _i=0; while [ -e "$ROOT/$_generation-$_i" ]; do _i=$((_i+1)); done
  _generation="$_generation-$_i"
  mkdir -m 700 "$ROOT/$_generation" || return 1
  printf '%s\n' "$S" > "$ROOT/$_generation/state.json" || return 1
  compile_config "$ROOT/$_generation/state.json" > "$ROOT/$_generation/config.json" || return 1
  "$BIN" run -test -config "$ROOT/$_generation/config.json" > "$WORK/core-check.log" 2>&1 || {
    fail '内核检查失败，运行配置未改变'; return 1;
  }
  _old=$(readlink "$ROOT/current" 2>/dev/null || :)
  _old_count=0
  [ ! -f "$ROOT/current/state.json" ] || _old_count=$(jq '.entries|length' "$ROOT/current/state.json")
  _was_active=no; active && _was_active=yes
  _was_boot=no; boot && _was_boot=yes
  _count=$(printf '%s' "$S" | jq '.entries|length')
  [ ! -e "$ROOT/pending-$$" ] && [ ! -L "$ROOT/pending-$$" ] || return 1
  ln -s "$_generation" "$ROOT/pending-$$" && mv -fT "$ROOT/pending-$$" "$ROOT/current" || return 1
  _ok=yes
  if [ "$_count" -gt 0 ]; then
    svc restart >/dev/null 2>&1 || _ok=no
    sleep 2
    active || _ok=no
    if [ "$_ok" = yes ] && [ "$_old_count" -eq 0 ]; then svc enable >/dev/null 2>&1 || _ok=no; fi
  else
    svc stop >/dev/null 2>&1 || _ok=no
    svc disable >/dev/null 2>&1 || _ok=no
  fi
  if [ "$_ok" != yes ]; then
    if [ -n "$_old" ]; then
      ln -s "$_old" "$ROOT/pending-$$" && mv -fT "$ROOT/pending-$$" "$ROOT/current" || return 1
    else rm -f -- "$ROOT/current"; fi
    _rollback_ok=yes
    if [ "$_was_active" = yes ]; then svc restart >/dev/null 2>&1 || _rollback_ok=no
    else svc stop >/dev/null 2>&1 || _rollback_ok=no; fi
    if [ "$_was_boot" = yes ]; then svc enable >/dev/null 2>&1 || _rollback_ok=no
    else svc disable >/dev/null 2>&1 || _rollback_ok=no; fi
    if [ "$_rollback_ok" = yes ]; then fail '启动失败，已回退旧配置及服务设置'
    else fail '旧配置已恢复，但服务恢复异常，请查看服务日志'; fi
    return 1
  fi
  if [ "$_count" -eq 0 ]; then say '最后一个节点已删除，服务和自启已关闭。'
  else say '配置已生效，旧版本保留；现有连接可能短暂中断。'; fi
}
pick_entry() {
  _total=$(printf '%s' "$S" | jq '.entries|length')
  [ "$_total" -gt 0 ] || { fail '尚无节点'; return 1; }
  printf '%s' "$S" | jq -r '.entries|to_entries[]|"\(.key+1). \(.value.name) / \(.value.inbound.port)"'
  required '选择节点' 1 || return 1
  case "$REPLY" in *[!0-9]*|'') return 1;;esac
  [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "$_total" ] || return 1
  IDX=$((REPLY-1)); E=$(printf '%s' "$S" | jq --argjson i "$IDX" '.entries[$i]')
}
put_entry() { update_s --argjson i "$IDX" --argjson e "$E" '.entries[$i]=$e'; }
show_path() {
  printf '%s' "$E" | jq -r '"客户端 → \(.name) [\(.inbound.protocol)] \(.host):\(.inbound.port)"'
  _route=$(printf '%s' "$E" | jq -r '.out')
  if [ "$_route" = direct ]; then say '  → 本机直接出网 → 访问目标'
  else printf '%s' "$S" | jq -r --arg t "$_route" '.outbounds[]|select(.tag==$t)|"  → \(.protocol) \(.settings.address):\(.settings.port) → 访问目标"'; fi
}
read_target() {
  required '代理服务器 IP 或域名' || return 1; HOST=$REPLY
  valid_host "$HOST" || return 1
  required '代理服务器端口' || return 1; PORT=$REPLY
  valid_port "$PORT" || return 1
  PORT=$(printf '%s' "$PORT" | sed 's/^0*//')
}
ss_method() {
  say '1. aes-128-gcm  2. aes-256-gcm  3. chacha20-ietf-poly1305'
  say '4. 2022-blake3-aes-128-gcm  5. 2022-blake3-aes-256-gcm  6. 2022-blake3-chacha20-poly1305'
  ask '加密方法' 3 || return 1
  case "$REPLY" in 1) METHOD=aes-128-gcm;;2) METHOD=aes-256-gcm;;3) METHOD=chacha20-ietf-poly1305;;
    4) METHOD=2022-blake3-aes-128-gcm;;5) METHOD=2022-blake3-aes-256-gcm;;6) METHOD=2022-blake3-chacha20-poly1305;;*) return 1;;esac
}
check_ss() {
  case "$METHOD" in
    aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305) [ -n "$PASSWORD" ];;
    2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
      case "$PASSWORD" in :*|*:|*::*) return 1;;esac
      _size=32; [ "$METHOD" != 2022-blake3-aes-128-gcm ] || _size=16
      _save_ifs=$IFS; IFS=:; set -f; set -- $PASSWORD; set +f; IFS=$_save_ifs
      [ "$#" -gt 0 ] || return 1
      for _key do
        _bytes=$(printf '%s' "$_key" | base64 -d 2>/dev/null | wc -c)
        [ "$_bytes" -eq "$_size" ] || return 1
        _canonical=$(printf '%s' "$_key" | base64 -d 2>/dev/null | base64 | tr -d '\n')
        [ "$_canonical" = "$_key" ] || return 1
      done;;
    *) return 1;;
  esac
}
reset_out() {
  USER=; PASSWORD=; UUID=; FLOW=; CIPHER=auto; NET=raw; SEC=none; SNI=; PUB=; SID=; FP=; ALPN=; SPX=; URLPATH=/; WSHOST=; GRPC=; MODE=; METHOD=
}
make_outbound() {
  valid_host "$HOST" && valid_port "$PORT" || return 1
  PORT=$(printf '%s' "$PORT" | sed 's/^0*//')
  _settings=$(jq -n --arg h "$HOST" --argjson p "$PORT" '{address:$h,port:$p}') || return 1
  case "$PROTO" in
    socks|http) _settings=$(printf '%s' "$_settings" | jq --arg u "$USER" --arg p "$PASSWORD" 'if $u!="" then .+{user:$u,pass:$p} else . end');;
    shadowsocks) check_ss || return 1
      _settings=$(printf '%s' "$_settings" | jq --arg m "$METHOD" --arg p "$PASSWORD" '.+{method:$m,password:$p}');;
    vless|vmess) valid_uuid "$UUID" || return 1
      _settings=$(printf '%s' "$_settings" | jq --arg id "$UUID" --arg f "$FLOW" --arg proto "$PROTO" --arg sc "$CIPHER" '.+{id:$id}+(if $proto=="vless" then {encryption:"none",flow:$f} else {security:$sc} end)');;
    trojan) [ -n "$PASSWORD" ] || return 1
      _settings=$(printf '%s' "$_settings" | jq --arg p "$PASSWORD" '.+{password:$p}');;
    *) return 1;;
  esac
  O=$(jq -n --arg p "$PROTO" --argjson s "$_settings" '{protocol:$p,settings:$s}') || return 1
  case "$PROTO" in socks|http|shadowsocks) return 0;;esac
  case "$NET" in tcp|raw) NET=raw;;ws|grpc) :;;*) fail '传输仅支持 TCP/RAW、WS、gRPC'; return 1;;esac
  case "$SEC" in none|tls|reality) :;;*) return 1;;esac
  if [ -n "$FLOW" ]; then
    [ "$PROTO" = vless ] && [ "$FLOW" = xtls-rprx-vision ] && [ "$NET" = raw ] && [ "$SEC" != none ] || return 1
  fi
  ST=$(jq -n --arg n "$NET" --arg s "$SEC" '{network:$n,security:$s}') || return 1
  case "$SEC" in
    tls) [ -n "$SNI" ] || SNI=$HOST
      ST=$(printf '%s' "$ST" | jq --arg s "$SNI" --arg f "$FP" --arg a "$ALPN" '.tlsSettings={serverName:$s,allowInsecure:false} | if $f!="" then .tlsSettings.fingerprint=$f else . end | if $a!="" then .tlsSettings.alpn=($a|split(",")) else . end');;
    reality) [ "$PROTO" = vless ] && [ "$NET" = raw ] && [ -n "$PUB" ] && [ -n "$SNI" ] || return 1
      [ -n "$FP" ] || FP=chrome
      ST=$(printf '%s' "$ST" | jq --arg s "$SNI" --arg k "$PUB" --arg i "$SID" --arg f "$FP" --arg x "$SPX" '.realitySettings={serverName:$s,password:$k,shortId:$i,fingerprint:$f}|if $x!="" then .realitySettings.spiderX=$x else . end');;
  esac
  case "$NET" in
    ws) ST=$(printf '%s' "$ST" | jq --arg p "$URLPATH" --arg h "$WSHOST" '.wsSettings={path:$p,headers:{}}|if $h!="" then .wsSettings.headers.Host=$h else . end');;
    grpc) ST=$(printf '%s' "$ST" | jq --arg s "$GRPC" --arg m "$MODE" '.grpcSettings={serviceName:$s,multiMode:($m=="multi")}');;
  esac
  O=$(printf '%s' "$O" | jq --argjson s "$ST" '.streamSettings=$s')
}
manual_out() {
  reset_out
  say '1. SOCKS5  2. Shadowsocks  3. HTTP CONNECT  4. VLESS Reality/TLS  5. Trojan TLS  6. 导入节点链接'
  ask '代理协议' 1 || return 1
  TYPE=$REPLY
  if [ "$TYPE" = 6 ]; then required '粘贴单节点链接（隐藏输入）' '' secret || return 1; import_link "$REPLY"; return $?; fi
  read_target || return 1
  case "$TYPE" in
    1|3) PROTO=socks; [ "$TYPE" != 3 ] || PROTO=http
      if yes '是否需要账号密码'; then required '账号' || return 1; USER=$REPLY; required '密码' '' secret || return 1; PASSWORD=$REPLY; fi;;
    2) PROTO=shadowsocks; ss_method || return 1; required 'SS 密码/密钥' '' secret || return 1; PASSWORD=$REPLY;;
    4) PROTO=vless; required 'UUID' || return 1; UUID=$REPLY
      say '1. Reality + Vision  2. TLS + Vision  3. TLS 无 Vision'; ask '传输安全' 1 || return 1
      SEC=tls; FLOW=xtls-rprx-vision
      case "$REPLY" in 1) SEC=reality;;2) :;;3) FLOW=;;*) return 1;;esac
      required 'SNI 域名' || return 1; SNI=$REPLY
      if [ "$SEC" = reality ]; then required '公钥 pbk' || return 1; PUB=$REPLY; ask 'shortId（可空）' || return 1; SID=$REPLY; fi;;
    5) PROTO=trojan; SEC=tls; required '密码' '' secret || return 1; PASSWORD=$REPLY; required 'SNI' "$HOST" || return 1; SNI=$REPLY;;
    *) return 1;;
  esac
  make_outbound
}
parse_authority() {
  _authority=$1
  case "$_authority" in
    \[*\]:*) HOST=${_authority%%\]*}; HOST=${HOST#\[}; PORT=${_authority##*\]:};;
    *:*) HOST=${_authority%:*}; PORT=${_authority##*:}; case "$HOST" in *:*) return 1;;esac;;
    *) return 1;;
  esac
  valid_host "$HOST" && valid_port "$PORT" || return 1
  PORT=$(printf '%s' "$PORT" | sed 's/^0*//')
}
get_q() { printf '%s' "$Q" | jq -r --arg k "$1" --arg d "${2-}" 'if has($k) then .[$k] else $d end'; }
import_link() {
  reset_out
  LINK=$(printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  case "$LINK" in
    vmess://*)
      D=$(b64d "${LINK#vmess://}") || return 1
      printf '%s' "$D" | jq -e '(.aid//0|tonumber)==0' >/dev/null || return 1
      HOST=$(printf '%s' "$D"|jq -r '.add'); PORT=$(printf '%s' "$D"|jq -r '.port'); valid_host "$HOST" && valid_port "$PORT" || return 1
      PROTO=vmess; UUID=$(printf '%s' "$D"|jq -r '.id'); CIPHER=$(printf '%s' "$D"|jq -r '.scy//"auto"')
      NET=$(printf '%s' "$D"|jq -r '.net//"tcp"'); SEC=$(printf '%s' "$D"|jq -r '.tls//"none"|if .=="" then "none" else . end')
      SNI=$(printf '%s' "$D"|jq -r '.sni//""'); WSHOST=$(printf '%s' "$D"|jq -r '.host//""'); URLPATH=$(printf '%s' "$D"|jq -r '.path//"/"')
      FP=$(printf '%s' "$D"|jq -r '.fp//""'); ALPN=$(printf '%s' "$D"|jq -r '.alpn//""'); GRPC=$URLPATH
      _head=$(printf '%s' "$D"|jq -r '.type//"none"'); [ "$NET" = grpc ] || [ "$_head" = none ] || return 1
      printf '%s' "$D" | jq -e '(.allowInsecure//false|tostring|ascii_downcase) as $v|($v=="false" or $v=="0" or $v=="")' >/dev/null || return 1
      make_outbound; return $?;;
  esac
  PROTO=${LINK%%://*}; [ "$PROTO" != "$LINK" ] || return 1
  RAW=${LINK#*://}; RAW=${RAW%%#*}; QUERY=
  case "$RAW" in *\?*) QUERY=${RAW#*\?}; RAW=${RAW%%\?*};;esac
  Q='{}'
  while [ -n "$QUERY" ]; do
    PAIR=${QUERY%%&*}; if [ "$PAIR" = "$QUERY" ]; then QUERY=; else QUERY=${QUERY#*&}; fi
    K=$(unuri "${PAIR%%=*}") || return 1
    case "$PAIR" in *=*) V=$(unuri "${PAIR#*=}") || return 1;;*) V=;;esac
    printf '%s' "$Q" | jq -e --arg k "$K" 'has($k)' >/dev/null && { fail '链接含重复参数'; return 1; }
    Q=$(printf '%s' "$Q" | jq --arg k "$K" --arg v "$V" '.[$k]=$v') || return 1
  done
  case "$PROTO" in
    ss)
      [ "$Q" = '{}' ] || { fail '不支持 SS 插件或额外参数'; return 1; }
      case "$RAW" in *@*) :;;*) RAW=$(b64d "$RAW") || return 1;;esac
      AUTH=${RAW%@*}; parse_authority "${RAW##*@}" || return 1
      AUTH=$(unuri "$AUTH") || return 1
      case "$AUTH" in *:*) :;;*) AUTH=$(b64d "$AUTH") || return 1;;esac
      METHOD=${AUTH%%:*}; PASSWORD=${AUTH#*:}; PROTO=shadowsocks
      make_outbound; return $?;;
    socks|socks5|http|vless|trojan) :;;*) fail '不支持该分享链接协议'; return 1;;
  esac
  case "$RAW" in */) RAW=${RAW%/};;esac
  case "$RAW" in */*) return 1;;esac
  AUTH=
  case "$RAW" in *@*) AUTH=${RAW%@*}; RAW=${RAW##*@};;esac
  parse_authority "$RAW" || return 1
  case "$PROTO" in
    socks|socks5|http)
      [ "$Q" = '{}' ] || return 1
      [ "$PROTO" != socks5 ] || PROTO=socks
      case "$AUTH" in *:*) USER=$(unuri "${AUTH%%:*}") || return 1; PASSWORD=$(unuri "${AUTH#*:}") || return 1;;'') :;;*) USER=$(unuri "$AUTH") || return 1;;esac
      make_outbound; return $?;;
  esac
  printf '%s' "$Q" | jq -e '(keys-["encryption","flow","security","sni","fp","pbk","sid","spx","type","path","host","serviceName","mode","alpn","headerType","allowInsecure","remarks"]|length)==0' >/dev/null || { fail '链接含未支持参数'; return 1; }
  case "$(get_q allowInsecure 0)" in 0|false|'') :;;*) return 1;;esac
  [ "$(get_q encryption none)" = none ] && [ "$(get_q headerType none)" = none ] || return 1
  NET=$(get_q type tcp); SEC=$(get_q security none); FLOW=$(get_q flow); SNI=$(get_q sni); FP=$(get_q fp); ALPN=$(get_q alpn)
  PUB=$(get_q pbk); SID=$(get_q sid); SPX=$(get_q spx); URLPATH=$(get_q path /); WSHOST=$(get_q host); GRPC=$(get_q serviceName); MODE=$(get_q mode)
  if [ "$PROTO" = trojan ]; then PASSWORD=$(unuri "$AUTH") || return 1; SEC=$(get_q security tls)
  else UUID=$(unuri "$AUTH") || return 1; fi
  make_outbound
}
pick_out() {
  say '本机如何出网？ 1. 直接出网  2. 添加代理节点  3. 使用已保存的代理节点'
  ask '选择' 1 || return 1
  case "$REPLY" in
    1) OUT=direct;;
    2) manual_out || return 1
      OUT="out-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
      O=$(printf '%s' "$O" | jq --arg t "$OUT" '.tag=$t') || return 1
      update_s --argjson o "$O" '.outbounds += [$o]' || return 1;;
    3) _n=$(printf '%s' "$S"|jq '.outbounds|length'); [ "$_n" -gt 0 ] || return 1
      printf '%s' "$S"|jq -r '.outbounds|to_entries[]|"\(.key+1). \(.value.protocol) / \(.value.settings.address):\(.value.settings.port)"'
      required '选择代理节点' 1 || return 1
      case "$REPLY" in *[!0-9]*|'') return 1;;esac
      [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "$_n" ] || return 1
      OUT=$(printf '%s' "$S"|jq -r --argjson i "$((REPLY-1))" '.outbounds[$i].tag');;
    *) return 1;;
  esac
}
show_links() {
  _h=$(printf '%s' "$E"|jq -r '.host'); _p=$(printf '%s' "$E"|jq -r '.inbound.port'); _ep=$(endpoint "$_h" "$_p"); _label=$(uri "$(printf '%s' "$E"|jq -r '.name')")
  _proto=$(printf '%s' "$E"|jq -r '.inbound.protocol')
  case "$_proto" in
    vless)
      _q=$(printf '%s' "$E"|jq -r '{encryption:"none",security:"reality",flow:"xtls-rprx-vision",sni:.inbound.streamSettings.realitySettings.serverNames[0],fp:"chrome",pbk:.public_key,sid:.inbound.streamSettings.realitySettings.shortIds[0],type:"tcp"}|to_entries|map((.key|@uri)+"="+(.value|@uri))|join("&")')
      printf '%s' "$E"|jq -r '.inbound.settings.clients[].id'|while IFS= read -r _id; do printf 'vless://%s@%s?%s#%s\n' "$_id" "$_ep" "$_q" "$_label"; done;;
    shadowsocks)
      _auth=$(printf '%s' "$E"|jq -r '.inbound.settings|.method+":"+.password')
      _encoded=$(printf '%s' "$_auth"|base64|tr -d '\n='|tr '/+' '_-')
      printf 'ss://%s@%s#%s\n' "$_encoded" "$_ep" "$_label";;
    socks)
      _u=$(uri "$(printf '%s' "$E"|jq -r '.inbound.settings.accounts[0].user')")
      _pw=$(uri "$(printf '%s' "$E"|jq -r '.inbound.settings.accounts[0].pass')")
      printf 'socks5://%s:%s@%s#%s\n' "$_u" "$_pw" "$_ep" "$_label";;
  esac
}
new_entry() {
  _advanced=${1-no}
  required '节点名称' || return 1; NAME=$REPLY
  printf '%s' "$S"|jq -e --arg n "$NAME" '.entries|any(.name==$n)' >/dev/null && { fail '名称已存在'; return 1; }
  ENTRY_TYPE=1
  if [ "$_advanced" = yes ]; then say '客户端连接本机：1. Reality + Vision  2. SS  3. SOCKS5'; ask '协议' 1 || return 1; ENTRY_TYPE=$REPLY; fi
  case "$ENTRY_TYPE" in 1|2|3) :;;*) return 1;;esac
  required '本机监听端口' 443 || return 1; LISTEN_PORT=$REPLY
  valid_port "$LISTEN_PORT" || return 1; LISTEN_PORT=$(printf '%s' "$LISTEN_PORT"|sed 's/^0*//')
  printf '%s' "$S"|jq -e --argjson p "$LISTEN_PORT" '.entries|any(.inbound.port==$p)' >/dev/null && { fail '端口已在本工具中使用'; return 1; }
  required '客户端连接的公网 IP 或域名' || return 1; PUBLIC_HOST=$REPLY; valid_host "$PUBLIC_HOST" || return 1
  TAG="in-$(od -An -N4 -tx1 /dev/urandom|tr -d ' \n')"
  PUBLIC=
  case "$ENTRY_TYPE" in
    1)
      required 'UUID（回车生成）' "$("$BIN" uuid)" || return 1; UUID=$REPLY; valid_uuid "$UUID" || return 1
      required 'Reality 域名 SNI' || return 1; SNI=$REPLY; valid_host "$SNI" || return 1
      required 'Reality 目标端口' 443 || return 1; TARGET_PORT=$REPLY; valid_port "$TARGET_PORT" || return 1
      KEYS=$("$BIN" x25519) || return 1
      PRIVATE=$(printf '%s\n' "$KEYS"|sed -n 's/^PrivateKey: *//p')
      PUBLIC=$(printf '%s\n' "$KEYS"|sed -n -e 's/^Password (PublicKey): *//p' -e 's/^PublicKey: *//p' -e 's/^Password: *//p')
      [ -n "$PRIVATE" ] && [ -n "$PUBLIC" ] || return 1
      SID=$(od -An -N8 -tx1 /dev/urandom|tr -d ' \n'); TARGET=$(endpoint "$SNI" "$TARGET_PORT")
      I=$(jq -n --arg t "$TAG" --argjson p "$LISTEN_PORT" --arg id "$UUID" --arg target "$TARGET" --arg s "$SNI" --arg k "$PRIVATE" --arg sid "$SID" '{tag:$t,listen:"0.0.0.0",port:$p,protocol:"vless",settings:{decryption:"none",clients:[{id:$id,email:("user-"+($id[0:8])),flow:"xtls-rprx-vision"}]},streamSettings:{network:"raw",security:"reality",realitySettings:{target:$target,serverNames:[$s],privateKey:$k,shortIds:[$sid],xver:0,show:false}}}') || return 1;;
    2)
      ss_method || return 1
      _length=32; [ "$METHOD" != 2022-blake3-aes-128-gcm ] || _length=16
      GENERATED=$(dd if=/dev/urandom bs="$_length" count=1 2>/dev/null|base64|tr -d '\n')
      ask 'SS 密码/密钥（留空自动生成，输入隐藏）' '' secret || return 1; PASSWORD=${REPLY:-$GENERATED}
      case "$METHOD" in 2022-*) case "$PASSWORD" in *:*) return 1;;esac;;esac
      check_ss || return 1
      I=$(jq -n --arg t "$TAG" --argjson p "$LISTEN_PORT" --arg m "$METHOD" --arg pw "$PASSWORD" '{tag:$t,listen:"0.0.0.0",port:$p,protocol:"shadowsocks",settings:{method:$m,password:$pw,network:"tcp,udp"}}') || return 1;;
    3)
      say 'SOCKS5 本身不加密链路，建议仅在可信网络中使用。'
      required 'SOCKS 账号' || return 1; USER=$REPLY
      required 'SOCKS 密码（输入隐藏）' '' secret || return 1; PASSWORD=$REPLY
      I=$(jq -n --arg t "$TAG" --argjson p "$LISTEN_PORT" --arg u "$USER" --arg pw "$PASSWORD" '{tag:$t,listen:"0.0.0.0",port:$p,protocol:"socks",settings:{auth:"password",accounts:[{user:$u,pass:$pw}],udp:false}}') || return 1;;
  esac
  E=$(jq -n --arg n "$NAME" --arg h "$PUBLIC_HOST" --argjson i "$I" --arg key "$PUBLIC" '{name:$n,host:$h,inbound:$i,public_key:$key,out:"direct"}') || return 1
  pick_out || return 1
  E=$(printf '%s' "$E"|jq --arg o "$OUT" '.out=$o') || return 1
  show_path
  if ! yes '确认保存并立即生效'; then say '已取消，运行配置未改变。'; return 0; fi
  update_s --argjson e "$E" '.entries+=[$e]' && apply_state || return 1
  say "请在主机防火墙及云安全组放行 TCP $LISTEN_PORT（SS 还需 UDP）。"
  if yes '现在测试出网链路'; then test_selected || say '测试未通过，节点已保存，可稍后重试。'; fi
  show_links
}
edit_entry() {
  pick_entry || return 1
  say '1. 名称  2. 公网地址  3. 监听端口  4. Reality 域名/目标端口  5. SS/SOCKS 凭据'
  ask '修改哪项' 1 || return 1
  case "$REPLY" in
    1) required '新名称' "$(printf '%s' "$E"|jq -r '.name')" || return 1
      printf '%s' "$S"|jq -e --arg n "$REPLY" --argjson i "$IDX" '.entries|to_entries|any(.key!=$i and .value.name==$n)' >/dev/null && return 1
      E=$(printf '%s' "$E"|jq --arg n "$REPLY" '.name=$n');;
    2) required '公网 IP 或域名' "$(printf '%s' "$E"|jq -r '.host')" || return 1; valid_host "$REPLY" || return 1
      E=$(printf '%s' "$E"|jq --arg h "$REPLY" '.host=$h');;
    3) required '新监听端口' "$(printf '%s' "$E"|jq -r '.inbound.port')" || return 1; valid_port "$REPLY" || return 1
      _port=$(printf '%s' "$REPLY"|sed 's/^0*//')
      printf '%s' "$S"|jq -e --argjson p "$_port" --argjson i "$IDX" '.entries|to_entries|any(.key!=$i and .value.inbound.port==$p)' >/dev/null && return 1
      E=$(printf '%s' "$E"|jq --argjson p "$_port" '.inbound.port=$p');;
    4) [ "$(printf '%s' "$E"|jq -r '.inbound.protocol')" = vless ] || return 1
      required 'Reality 域名' "$(printf '%s' "$E"|jq -r '.inbound.streamSettings.realitySettings.serverNames[0]')" || return 1; SNI=$REPLY; valid_host "$SNI" || return 1
      required '目标端口' 443 || return 1; valid_port "$REPLY" || return 1; _target=$(endpoint "$SNI" "$REPLY")
      E=$(printf '%s' "$E"|jq --arg s "$SNI" --arg t "$_target" '.inbound.streamSettings.realitySettings|=. +{serverNames:[$s],target:$t}');;
    5) _proto=$(printf '%s' "$E"|jq -r '.inbound.protocol')
      case "$_proto" in
        shadowsocks) METHOD=$(printf '%s' "$E"|jq -r '.inbound.settings.method'); required '新密码/密钥' '' secret || return 1; PASSWORD=$REPLY
          case "$METHOD" in 2022-*) case "$PASSWORD" in *:*) return 1;;esac;;esac
          check_ss || return 1; E=$(printf '%s' "$E"|jq --arg p "$PASSWORD" '.inbound.settings.password=$p');;
        socks) required '账号' || return 1; USER=$REPLY; required '密码' '' secret || return 1; PASSWORD=$REPLY
          E=$(printf '%s' "$E"|jq --arg u "$USER" --arg p "$PASSWORD" '.inbound.settings.accounts=[{user:$u,pass:$p}]');;
        *) fail 'Reality 请在 UUID 用户管理中修改'; return 1;;
      esac;;
    *) return 1;;
  esac
  show_path
  if yes '确认保存并立即生效（更改后需重新导入客户端链接）'; then put_entry && apply_state && show_links; fi
}
pick_user() {
  printf '%s' "$E"|jq -r '.inbound.settings.clients|to_entries[]|"\(.key+1). \(.value.email//"user") / \(.value.id[0:8])…"'
  required '选择用户' 1 || return 1
  case "$REPLY" in *[!0-9]*|'') return 1;;esac
  [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "$(printf '%s' "$E"|jq '.inbound.settings.clients|length')" ] || return 1
  USER_IDX=$((REPLY-1))
}
users_menu() {
  pick_entry || return 1
  [ "$(printf '%s' "$E"|jq -r '.inbound.protocol')" = vless ] || return 1
  say '1. 添加 UUID  2. 修改 UUID  3. 删除 UUID'; ask '选择' 1 || return 1; ACTION=$REPLY
  case "$ACTION" in
    1|2) if [ "$ACTION" = 2 ]; then pick_user || return 1; fi
      required '新 UUID（回车生成）' "$("$BIN" uuid)" || return 1; UUID=$REPLY; valid_uuid "$UUID" || return 1
      _exclude=-1; [ "$ACTION" != 2 ] || _exclude=$USER_IDX
      printf '%s' "$E"|jq -e --arg id "$UUID" --argjson x "$_exclude" '.inbound.settings.clients|to_entries|any(.key!=$x and .value.id==$id)' >/dev/null && { fail 'UUID 已存在'; return 1; }
      if [ "$ACTION" = 1 ]; then E=$(printf '%s' "$E"|jq --arg id "$UUID" '.inbound.settings.clients +=[{id:$id,email:("user-"+($id[0:8])),flow:"xtls-rprx-vision"}]')
      else E=$(printf '%s' "$E"|jq --argjson i "$USER_IDX" --arg id "$UUID" '.inbound.settings.clients[$i].id=$id'); fi;;
    3) [ "$(printf '%s' "$E"|jq '.inbound.settings.clients|length')" -gt 1 ] || { fail '最后一个用户请通过删除整个节点处理'; return 1; }
      pick_user || return 1
      E=$(printf '%s' "$E"|jq --argjson i "$USER_IDX" 'del(.inbound.settings.clients[$i])');;
    *) return 1;;
  esac
  if yes '确认保存并立即生效（删除用户会撤销旧链接；历史备份保留）'; then
    put_entry && apply_state || return 1
    [ "$ACTION" = 3 ] || show_links
  fi
}
service_menu() {
  if active; then say '服务：运行中'; else say '服务：停止'; fi
  if boot; then say '开机自启：开启'; else say '开机自启：关闭'; fi
  say '1. 启动/重启  2. 仅停止  3. 开启自启  4. 关闭自启  5. 停止并关闭自启  0. 返回'
  ask '选择' 0 || return 1
  case "$REPLY" in
    1|3) [ "$(printf '%s' "$S"|jq '.entries|length')" -gt 0 ] || return 1
      if [ "$REPLY" = 1 ]; then svc restart; else svc enable; fi;;
    2) svc stop;;4) svc disable;;5) svc stop && svc disable;;0) :;;*) return 1;;
  esac
}
test_selected() {
  show_path
  say '测试本机出网与 HTTPS，不代替公网客户端到入口的握手测试。'
  _proto=$(printf '%s' "$E"|jq -r '.inbound.protocol')
  if [ "$_proto" = vless ]; then
    _sni=$(printf '%s' "$E"|jq -r '.inbound.streamSettings.realitySettings.serverNames[0]')
    _target=$(printf '%s' "$E"|jq -r '.inbound.streamSettings.realitySettings.target'); _tp=${_target##*:}
    if curl --noproxy '*' --tlsv1.3 --tls-max 1.3 --connect-timeout 5 --max-time 8 -sS -I -o /dev/null "https://$_sni:$_tp/"; then say 'Reality 目标 TLS 1.3 和证书检查通过。'
    else say 'Reality 目标检查失败，请核对域名。'; fi
  fi
  _out=$(printf '%s' "$E"|jq -r '.out')
  if [ "$_out" = direct ]; then O='{"protocol":"freedom"}'
  else O=$(printf '%s' "$S"|jq -c --arg t "$_out" '.outbounds[]|select(.tag==$t)'); fi
  [ -n "$O" ] || return 1
  _random=$(od -An -N2 -tu2 /dev/urandom|tr -d ' '); _port=$((20000+_random%40000))
  _password=$(od -An -N16 -tx1 /dev/urandom|tr -d ' \n')
  _probe=$(jq -n --argjson p "$_port" --arg pw "$_password" --argjson o "$O" '{log:{loglevel:"none"},inbounds:[{listen:"127.0.0.1",port:$p,protocol:"socks",settings:{auth:"password",accounts:[{user:"probe",pass:$pw}],udp:false}}],outbounds:[$o]}') || return 1
  printf '%s' "$_probe" | "$BIN" run -config stdin: >/dev/null 2>&1 &
  PROBE_PID=$!; sleep 1; _result=1
  if kill -0 "$PROBE_PID" 2>/dev/null; then
    _status=$(curl --noproxy '' --proxy "socks5h://127.0.0.1:$_port" --proxy-user "probe:$_password" --connect-timeout 5 --max-time 15 -sS -I -o /dev/null -w '%{http_code}' https://example.com/) && {
      case "$_status" in 2??|3??) say "出网 HTTPS 成功（状态码 $_status）。"; _result=0;;*) say "目标响应异常：$_status";;esac
    }
  else say '测试内核未启动（可能端口碰撞），可稍后重试。'; fi
  kill "$PROBE_PID" 2>/dev/null || :; wait "$PROBE_PID" 2>/dev/null || :; PROBE_PID=
  return "$_result"
}
uninstall_menu() {
  say '1. 返回  2. 卸载程序但保留配置/日志  3. 卸载并删除配置、密钥、备份和独立日志'
  ask '选择' 1 || return 1; UNINSTALL_MODE=$REPLY
  case "$UNINSTALL_MODE" in 1) return 0;;2|3) :;;*) return 1;;esac
  required '输入 UNINSTALL 确认（共享系统日志不会清除）' || return 1
  [ "$REPLY" = UNINSTALL ] || { say '已取消。'; return 0; }
  [ "$PROG" = /opt/xray-menu ] && [ ! -L "$PROG" ] && [ -f "$PROG/.managed-by-xray-menu" ] || return 1
  UNIT=/etc/systemd/system/xray-menu.service; [ "$INIT" != openrc ] || UNIT=/etc/init.d/xray-menu
  for _file in "$UNIT" /usr/local/bin/xray-menu; do
    [ ! -L "$_file" ] || return 1
    if [ -e "$_file" ]; then grep -q '^# Managed by xray-menu$' "$_file" || return 1; fi
  done
  [ "$ROOT" = /etc/xray-menu ] && [ ! -L "$ROOT" ] || return 1
  svc stop && svc disable || return 1
  rm -f -- "$UNIT" /usr/local/bin/xray-menu
  [ "$INIT" != systemd ] || systemctl daemon-reload
  cleanup; WORK=; LOCK_OWNED=no
  rm -rf -- "$PROG"
  if [ "$UNINSTALL_MODE" = 3 ]; then
    rm -rf -- "$ROOT"
    [ -L /var/log/xray-menu.log ] || rm -f -- /var/log/xray-menu.log
    say '程序、配置、历史密钥和独立日志已清除。'
  else say '程序已卸载，配置和日志保留。'; fi
  exit 0
}
advanced_menu() {
  say '1. 新建 SS/SOCKS/Reality 节点  2. 删除节点  3. 清理未使用出口  4. 卸载  0. 返回'
  ask '选择' 0 || return 1
  case "$REPLY" in
    1) new_entry yes;;
    2) pick_entry && show_path || return 1
      if yes '确认删除节点（最后一个节点删除后停用服务；历史备份保留）'; then update_s --argjson i "$IDX" 'del(.entries[$i])' && apply_state; fi;;
    3) if yes '确认清除当前配置未使用的代理出口（历史备份保留）'; then
        update_s '[.entries[].out] as $used | .outbounds |= map(select(.tag as $t | $used|index($t)))' && apply_state; fi;;
    4) uninstall_menu;;0) :;;*) return 1;;
  esac
}
main() {
  [ "$(id -u)" -eq 0 ] || { fail '请以 root 运行'; return 1; }
  for _cmd in jq curl base64 od; do command -v "$_cmd" >/dev/null 2>&1 || { fail "缺少 $_cmd"; return 1; }; done
  manager || return 1
  [ ! -L "$ROOT" ] || return 1
  mkdir -p "$ROOT" && chmod 700 "$ROOT" || return 1
  if ! mkdir "$ROOT/manager.lock.d" 2>/dev/null; then
    _pid=$(cat "$ROOT/manager.lock.d/pid" 2>/dev/null || :)
    case "$_pid" in ''|*[!0-9]*) fail '管理锁异常，请检查是否有其他管理器运行'; return 1;;esac
    if kill -0 "$_pid" 2>/dev/null; then fail '另一个管理器正在运行'; return 1; fi
    [ ! -L "$ROOT/manager.lock.d" ] || return 1
    rm -f -- "$ROOT/manager.lock.d/pid"; rmdir "$ROOT/manager.lock.d" && mkdir "$ROOT/manager.lock.d" || return 1
  fi
  LOCK_OWNED=yes; printf '%s\n' "$$" > "$ROOT/manager.lock.d/pid"
  WORK="$ROOT/.work-$$"; mkdir -m 700 "$WORK" || return 1
  trap cleanup 0
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  while :; do
    load_state || return 1
    say ''; say '=== Xray 轻量菜单 3.0-sh ==='
    say '1. 新建 Reality 节点  2. 查看连接路径  3. 编辑节点  4. UUID 用户管理'
    say '5. 更换出网方式  6. 导出链接  7. 测试出网  8. 服务/自启  9. 高级功能  0. 退出'
    ask '选择' 0 || return 0
    case "$REPLY" in
      1) new_entry || say '未完成，返回菜单。';;
      2) _n=$(printf '%s' "$S"|jq '.entries|length'); _j=0
        [ "$_n" -gt 0 ] || say '暂无节点，选择 1 创建。'
        while [ "$_j" -lt "$_n" ]; do E=$(printf '%s' "$S"|jq --argjson i "$_j" '.entries[$i]'); show_path; _j=$((_j+1)); done;;
      3) edit_entry || say '未完成，返回菜单。';;
      4) users_menu || say '未完成，返回菜单。';;
      5) if pick_entry && pick_out; then E=$(printf '%s' "$E"|jq --arg o "$OUT" '.out=$o'); show_path
           if yes '确认保存并立即生效'; then put_entry && apply_state || say '未完成。'; fi; fi;;
      6) if pick_entry; then show_links; fi;;
      7) if pick_entry; then test_selected || say '连接测试失败。'; fi;;
      8) service_menu || say '操作失败。';;
      9) advanced_menu || say '未完成，返回菜单。';;
      0) return 0;;*) say '无效选项。';;
    esac
  done
}
if [ "${XRAY_MENU_SOURCE_ONLY-}" != 1 ]; then main "$@"; fi
XRAY_MENU_SHELL
sh -n "$SESSION/manager.sh"
install -m 700 "$SESSION/manager.sh" /opt/xray-menu/manager.sh
if [ -f "$UNIT" ]; then cp -p "$UNIT" "$SESSION/service.previous"; fi
if [ "$INIT" = systemd ]; then
  cat > "$UNIT" <<'XRAY_UNIT'
# Managed by xray-menu
[Unit]
Description=Xray Menu managed proxy
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/opt/xray-menu/xray run -config /etc/xray-menu/current/config.json
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
UMask=0077
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
XRAY_UNIT
  systemctl daemon-reload
else
  cat > "$UNIT" <<'XRAY_OPENRC'
#!/sbin/openrc-run
# Managed by xray-menu
name="xray-menu"
description="Xray Menu managed proxy"
supervisor="supervise-daemon"
command="/opt/xray-menu/xray"
command_args="run -config /etc/xray-menu/current/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
respawn_delay=3
respawn_max=0
output_log="/var/log/xray-menu.log"
error_log="/var/log/xray-menu.log"
depend() { need net; after firewall; }
start_pre() {
  checkpath -f -m 0600 /var/log/xray-menu.log
  nofile_limit=65536
  nofile_hard=$(ulimit -Hn) || return 1
  case "$nofile_hard" in
    unlimited) : ;;
    ''|*[!0-9]*) return 1 ;;
    *) if [ "$nofile_hard" -lt "$nofile_limit" ]; then
         nofile_limit=$nofile_hard
       fi ;;
  esac
  ulimit -n "$nofile_limit" || return 1
}
XRAY_OPENRC
  chmod 755 "$UNIT"
fi
cat > /usr/local/bin/xray-menu <<'XRAY_COMMAND'
#!/bin/sh
# Managed by xray-menu
exec /bin/sh /opt/xray-menu/manager.sh "$@"
XRAY_COMMAND
chmod 755 /usr/local/bin/xray-menu
/opt/xray-menu/xray version
printf '\n安装完成。以后以 root 执行 xray-menu 打开菜单。\n'
exec /bin/sh /opt/xray-menu/manager.sh
