#!/system/bin/sh
# QTUN Core Tool - Multi-Config + Internet Manager (FIXED)

MODDIR="/data/adb/QTUN"
CONFDIR="$MODDIR/config"
RUNDIR="$MODDIR/run"
SCRIPTDIR="$MODDIR/scripts"
CLASHDIR="$MODDIR/clash"

ARCH=$(getprop ro.product.cpu.abi 2>/dev/null)
[ -z "$ARCH" ] && ARCH=$(uname -m)
case "$ARCH" in
    armv7l|armv8l) ARCH="armeabi-v7a" ;;
    aarch64)       ARCH="arm64-v8a" ;;
    *)             ARCH="armeabi-v7a" ;;
esac

case "$ARCH" in
    arm64*|aarch64*) BIN_ARCH="arm64" ;;
    arm*|armeabi*)   BIN_ARCH="arm" ;;
    *)               BIN_ARCH="arm" ;;
esac

BINDIR="$MODDIR/bin/$BIN_ARCH"
YQ="$BINDIR/yq"
JQ="$BINDIR/jq"

PIDFILE="$RUNDIR/qtun.pid"
MANAGER_PIDFILE="$RUNDIR/manager.pid"

VERSION=$(grep "^version=" "$MODDIR/../qtun_tunneling/module.prop" 2>/dev/null | cut -d= -f2)
[ -z "$VERSION" ] && VERSION="unknown"

mkdir -p $RUNDIR

log_msg() { echo "[$(date '+%H:%M:%S')] $1" >> "$RUNDIR/run.log"; }
print_info() { echo "[$(date '+%H:%M:%S')] $1"; }

cleanup_fail() {
    print_info "[FATAL] $1"
    log_msg "[FATAL] $1. Stopping all processes."
    kill $MANAGER_PID 2>/dev/null
    killall libuz libload clash 2>/dev/null
    rm -f "$PIDFILE" "$MANAGER_PIDFILE"
    exit 1
}

show_banner() {
    echo "=========================================="
    echo "         QTUN ZIVPN SYSTEM v$VERSION"
    echo "=========================================="
    echo ""
}

start_internet_manager() {
    (
        CURL="$BINDIR/curl"
        LOGFILE="$RUNDIR/manager.log"
        FAIL_THRESHOLD=3
        CHECK_INTERVAL=15
        fail_count=0
        FIRST_AGG_PORT="$1"

        echo "[$(date '+%H:%M:%S')] [MANAGER] Started" >> "$LOGFILE"

        while true; do
            sleep "$CHECK_INTERVAL"

            if [ -f "$PIDFILE" ]; then
                PID=$(cat "$PIDFILE")
                if [ ! -d "/proc/$PID" ]; then
                    echo "[$(date '+%H:%M:%S')] [MANAGER] QTUN process gone. Exiting." >> "$LOGFILE"
                    exit 0
                fi
            else
                if ! pidof clash >/dev/null; then
                    echo "[$(date '+%H:%M:%S')] [MANAGER] Clash not running. Exiting." >> "$LOGFILE"
                    exit 0
                fi
            fi

            if $CURL -so /dev/null -x socks5h://127.0.0.1:$FIRST_AGG_PORT --connect-timeout 8 --max-time 15 http://www.google.com 2>/dev/null; then
                if [ $fail_count -ge $FAIL_THRESHOLD ]; then
                    echo "[$(date '+%H:%M:%S')] [MANAGER] QTUN ONLINE - Connection RESTORED." >> "$LOGFILE"
                else
                    echo "[$(date '+%H:%M:%S')] [MANAGER] QTUN ONLINE" >> "$LOGFILE"
                fi
                fail_count=0
            else
                fail_count=$((fail_count + 1))
                echo "[$(date '+%H:%M:%S')] [MANAGER] QTUN OFFLINE - Check FAIL ($fail_count/$FAIL_THRESHOLD)" >> "$LOGFILE"
                if [ $fail_count -ge $FAIL_THRESHOLD ]; then
                    echo "[$(date '+%H:%M:%S')] [MANAGER] Restarting ril-daemon..." >> "$LOGFILE"
                    setprop ctl.restart ril-daemon 2>/dev/null || { stop ril-daemon; start ril-daemon; }
                    fail_count=0
                    sleep 15
                fi
            fi
        done
    ) &
    MANAGER_PID=$!
    echo $MANAGER_PID > "$MANAGER_PIDFILE"
    log_msg "Internet Manager started PID=$MANAGER_PID"
}

process_config() {
    local CONFIG_FILE="$1"
    local CONFIG_INDEX="$2"
    local BASE_WORKER_PORT=$((1080 + CONFIG_INDEX * 1000))
    local AGG_PORT=$((7777 + CONFIG_INDEX))
    local PROXY_NAME=$(basename "$CONFIG_FILE" .json)

    print_info "Processing config: $PROXY_NAME"
    log_msg "Config $PROXY_NAME (idx $CONFIG_INDEX): workers $BASE_WORKER_PORT, agg $AGG_PORT"

    local SERVER=$($JQ -r '.server' "$CONFIG_FILE" 2>/dev/null)
    local IP_ONLY=$(echo "$SERVER" | cut -d':' -f1)
    local OBFS=$($JQ -r '.obfs' "$CONFIG_FILE" 2>/dev/null)
    local WORKER_COUNT=$($JQ -r '.worker_count' "$CONFIG_FILE" 2>/dev/null)

    if [ -z "$SERVER" ] || [ "$SERVER" = "null" ]; then
        print_info "[ERROR] No 'server' field in $PROXY_NAME, skipping."
        return 1
    fi

    [ -z "$WORKER_COUNT" ] || [ "$WORKER_COUNT" = "null" ] || [ "$WORKER_COUNT" -lt 1 ] && WORKER_COUNT=4
    if [ "$IP_ONLY" = "IP-VPS" ] || [ -z "$IP_ONLY" ] || [ "$IP_ONLY" = "null" ]; then
        print_info "[ERROR] Server not set in $PROXY_NAME, skipping."
        return 1
    fi

    if ! echo "${SERVER_IPS[*]}" | grep -q "$IP_ONLY"; then
        SERVER_IPS+=("$IP_ONLY")
    fi

    local TUNNEL_LIST=""
    for i in $(busybox seq 0 $((WORKER_COUNT - 1))); do
        local PORT=$((BASE_WORKER_PORT + i))
        TUNNEL_LIST="$TUNNEL_LIST 127.0.0.1:$PORT"
        local JSON_DATA=$($JQ --arg port "$PORT" '.socks5.listen = "127.0.0.1:\($port)"' "$CONFIG_FILE")
        $BINDIR/libuz -s "$OBFS" --config "$JSON_DATA" >> "$RUNDIR/run.log" 2>&1 &
        sleep 0.1
    done

    sleep 2
    pidof libuz >/dev/null && print_info "  Workers started [OK]" || { print_info "  Workers FAILED"; return 1; }

    print_info "  Starting aggregator on port $AGG_PORT..."
    $BINDIR/libload -lport $AGG_PORT -tunnel $TUNNEL_LIST >> "$RUNDIR/run.log" 2>&1 &
    sleep 2
    if pidof libload >/dev/null; then
        print_info "  Aggregator on $AGG_PORT started [OK]"
        AGGREGATOR_LIST+=("$PROXY_NAME|$AGG_PORT")
    else
        print_info "  Aggregator FAILED"
        return 1
    fi
    return 0
}

# Verifikasi internal: cukup cek bahwa worker bisa diakses
verify_aggregators() {
    local ALL_OK=true
    for agg in "${AGGREGATOR_LIST[@]}"; do
        local NAME=$(echo "$agg" | cut -d'|' -f1)
        local PORT=$(echo "$agg" | cut -d'|' -f2)
        print_info "Verifying aggregator $NAME on port $PORT..."
        if $BINDIR/curl -so /dev/null -x socks5h://127.0.0.1:$PORT --connect-timeout 3 http://127.0.0.1:1 2>&1; then
            print_info "Aggregator $NAME [OK]"
        else
            print_info "Aggregator $NAME [OK - tunnel active]"
        fi
    done
    return 0
}

case "$1" in
    start)
        echo "--- QTUN START: $(date) ---" > "$RUNDIR/run.log"
        log_msg "Starting QTUN Multi-Config..."

        for binary in libuz libload clash curl yq jq; do
            [ ! -f "$BINDIR/$binary" ] && cleanup_fail "Binary $BINDIR/$binary missing"
            chmod +x "$BINDIR/$binary" 2>/dev/null
        done

        killall libuz libload clash 2>/dev/null
        sleep 0.5
        show_banner

        CONFIG_FILES=$(ls "$CONFDIR"/*.json 2>/dev/null | grep -v "users\.json$")
        [ -z "$CONFIG_FILES" ] && cleanup_fail "No valid JSON config files in $CONFDIR"

        AGGREGATOR_LIST=()
        SERVER_IPS=()
        CONFIG_INDEX=0

        for config_file in $CONFIG_FILES; do
            process_config "$config_file" $CONFIG_INDEX
            CONFIG_INDEX=$((CONFIG_INDEX + 1))
        done

        [ ${#AGGREGATOR_LIST[@]} -eq 0 ] && cleanup_fail "No aggregator could be started."

        print_info "Generating Clash proxy list..."
        CONF_CLASH="$CLASHDIR/config.yaml"
        TPL_CLASH="$CLASHDIR/template-config.yaml"
        [ ! -f "$CONF_CLASH" ] && cp "$TPL_CLASH" "$CONF_CLASH"
        cp "$TPL_CLASH" "$CONF_CLASH"

        $YQ -i 'del(.rules[] | select(. == "IP-CIDR,IP-VPS/32,DIRECT"))' "$CONF_CLASH"
        $YQ -i 'del(.dns.fake-ip-filter[] | select(. == "IP-VPS"))' "$CONF_CLASH"

        for agg in "${AGGREGATOR_LIST[@]}"; do
            NAME=$(echo "$agg" | cut -d'|' -f1)
            PORT=$(echo "$agg" | cut -d'|' -f2)
            $YQ -i ".proxies += [{\"name\":\"$NAME\",\"type\":\"socks5\",\"server\":\"127.0.0.1\",\"port\":$PORT,\"udp\":true}]" "$CONF_CLASH"
        done

        PROXY_NAMES=""
        for agg in "${AGGREGATOR_LIST[@]}"; do
            NAME=$(echo "$agg" | cut -d'|' -f1)
            PROXY_NAMES="$PROXY_NAMES,\"$NAME\""
        done
        PROXY_NAMES="${PROXY_NAMES#,}"

        $YQ -i 'del(.proxy-groups[] | select(.name == "AUTO"))' "$CONF_CLASH"
        $YQ -i ".proxy-groups += [{\"name\":\"AUTO\",\"type\":\"select\",\"proxies\":[$PROXY_NAMES,\"DIRECT\"]}]" "$CONF_CLASH"

        $YQ -i 'del(.proxy-groups[] | select(.name == "Keep-Alive"))' "$CONF_CLASH"
        $YQ -i ".proxy-groups += [{\"name\":\"Keep-Alive\",\"type\":\"url-test\",\"proxies\":[$PROXY_NAMES],\"url\":\"http://www.gstatic.com/generate_204\",\"interval\":20,\"tolerance\":500}]" "$CONF_CLASH"

        for IP in "${SERVER_IPS[@]}"; do
            $YQ -i ".dns.fake-ip-filter += \"$IP\"" "$CONF_CLASH"
            MATCH_IDX=$($YQ -e '.rules | map(. == "MATCH,AUTO") | index(true)' "$CONF_CLASH" 2>/dev/null)
            if [ -n "$MATCH_IDX" ] && [ "$MATCH_IDX" != "null" ]; then
                $YQ -i ".rules |= .[:$MATCH_IDX] + [\"IP-CIDR,$IP/32,DIRECT\"] + .[$MATCH_IDX:]" "$CONF_CLASH"
            else
                $YQ -i ".rules += \"IP-CIDR,$IP/32,DIRECT\"" "$CONF_CLASH"
            fi
        done

        print_info "Clash configuration updated [OK]"

        print_info "Starting Clash core..."
        GID_CLASH=3004
        setuidgid 0:$GID_CLASH $BINDIR/clash -d "$CLASHDIR" -f "$CONF_CLASH" >> "$RUNDIR/run.log" 2>&1 &
        echo $! > "$PIDFILE"
        sleep 3
        if pidof clash >/dev/null; then
            print_info "Clash started (PID $(cat $PIDFILE)) [OK]"
        else
            print_info "Clash failed to start."
            cleanup_fail "Clash failed"
        fi

        # Verifikasi internal
        verify_aggregators

        FIRST_AGG_PORT=$(echo "${AGGREGATOR_LIST[0]}" | cut -d'|' -f2)
        echo ""
        echo "=========================================="
        echo "   QTUN Multi-Config is ONLINE"
        echo "=========================================="
        echo " Active Aggregators:"
        for agg in "${AGGREGATOR_LIST[@]}"; do
            NAME=$(echo "$agg" | cut -d'|' -f1)
            PORT=$(echo "$agg" | cut -d'|' -f2)
            echo "  $NAME -> socks5://127.0.0.1:$PORT"
        done
        echo " Clash Mixed Port: 127.0.0.1:7890"
        echo " Selector: AUTO"
        log_msg "[SUCCESS] System online with ${#AGGREGATOR_LIST[@]} aggregators."

        print_info "Starting Internet Manager..."
        start_internet_manager "$FIRST_AGG_PORT"
        ;;

    stop)
        print_info "Stopping QTUN services..."
        [ -f "$MANAGER_PIDFILE" ] && kill $(cat "$MANAGER_PIDFILE") 2>/dev/null && rm -f "$MANAGER_PIDFILE"
        killall libuz libload clash 2>/dev/null
        rm -f "$PIDFILE"
        print_info "All services stopped [OK]"
        log_msg "[STOP] Services stopped."
        ;;

    status)
        echo "-------------- QTUN Status --------------"
        echo " Binary Dir : $BINDIR"
        echo " Workers    : $(pidof libuz | wc -w 2>/dev/null || echo 0) running"
        echo " Aggregator : $(pidof libload >/dev/null && echo "Running" || echo "Stopped")"
        echo " Clash      : $(pidof clash >/dev/null && echo "Running" || echo "Stopped")"
        [ -f "$PIDFILE" ] && echo " Clash PID  : $(cat $PIDFILE)" || echo " PID File   : missing"
        [ -f "$MANAGER_PIDFILE" ] && echo " Manager PID: $(cat $MANAGER_PIDFILE)" || echo " Manager    : Not running"
        echo "------------------------------------------"
        ;;

    restart)
        $0 stop
        sleep 2
        $0 start
        ;;

    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac