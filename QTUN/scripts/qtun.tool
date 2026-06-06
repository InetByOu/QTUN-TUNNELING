#!/system/bin/sh
# QTUN Core v7 - Configurable Internet Manager (per config)

MODDIR="/data/adb/QTUN"
CONFDIR="$MODDIR/config"
RUNDIR="$MODDIR/run"
CLASHDIR="$MODDIR/clash"
LOGFILE="$RUNDIR/run.log"
AGGREGATOR_MAP="$RUNDIR/aggregator_config.map"
FAILCOUNT_DIR="$RUNDIR/failcounts"
MANAGER_CONFIG="$RUNDIR/manager_config"

# Default values (akan ditimpa oleh config.json)
DEFAULT_CHECK_INTERVAL=20
DEFAULT_FAIL_THRESHOLD=2
DEFAULT_TIMEOUT=6
DEFAULT_TEST_URL="http://www.google.com"

# -------------------------------------------------------------------
#  Environment & binaries
# -------------------------------------------------------------------
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
CURL="$BINDIR/curl"

PIDFILE="$RUNDIR/qtun.pid"
MANAGER_PIDFILE="$RUNDIR/aggregator_manager.pid"
WORKER_CHECK_PIDFILE="$RUNDIR/worker_check.pid"
ROTATE_PIDFILE="$RUNDIR/log_rotate.pid"
INTERNET_MGR_PIDFILE="$RUNDIR/internet_manager.pid"

VERSION=$(grep "^version=" "$MODDIR/../qtun_tunneling/module.prop" 2>/dev/null | cut -d= -f2)
[ -z "$VERSION" ] && VERSION="unknown"

mkdir -p "$RUNDIR" "$FAILCOUNT_DIR"

# -------------------------------------------------------------------
#  Logging
# -------------------------------------------------------------------
log_msg() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOGFILE"; }
print_info() {
    local msg="[$(date '+%H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOGFILE"
}

cleanup_fail() {
    print_info "[FATAL] $1. Stopping all processes."
    log_msg "[FATAL] $1. Stopping all processes."
    kill "$MANAGER_PID" 2>/dev/null
    kill "$WORKER_CHECK_PID" 2>/dev/null
    kill "$INTERNET_MGR_PID" 2>/dev/null
    killall -9 libuz libload clash 2>/dev/null
    rm -f "$PIDFILE" "$MANAGER_PIDFILE" "$WORKER_CHECK_PIDFILE" "$INTERNET_MGR_PIDFILE"
    exit 1
}

show_banner() {
    echo "=========================================="
    echo "      QTUN ZIVPN SYSTEM v$VERSION"
    echo "   Configurable Internet Manager"
    echo "=========================================="
    echo ""
}

# -------------------------------------------------------------------
#  Load internet manager settings from config files
# -------------------------------------------------------------------
load_manager_settings() {
    # Reset to defaults
    MANAGER_ENABLED=0
    CHECK_INTERVAL=$DEFAULT_CHECK_INTERVAL
    FAIL_THRESHOLD=$DEFAULT_FAIL_THRESHOLD
    TIMEOUT=$DEFAULT_TIMEOUT
    TEST_URL="$DEFAULT_TEST_URL"
    RESTART_ON_FAILURE=1
    
    # Baca semua config, gunakan setting dari config pertama yang memiliki internet_manager.enabled=true
    for config_file in $(ls "$CONFDIR"/*.json 2>/dev/null | grep -v "users\.json$"); do
        local enabled=$($JQ -r '.internet_manager.enabled // false' "$config_file" 2>/dev/null)
        if [ "$enabled" = "true" ]; then
            MANAGER_ENABLED=1
            # Ambil semua setting dari config ini
            local tmp_interval=$($JQ -r '.internet_manager.check_interval // empty' "$config_file" 2>/dev/null)
            local tmp_threshold=$($JQ -r '.internet_manager.fail_threshold // empty' "$config_file" 2>/dev/null)
            local tmp_timeout=$($JQ -r '.internet_manager.timeout // empty' "$config_file" 2>/dev/null)
            local tmp_url=$($JQ -r '.internet_manager.test_url // empty' "$config_file" 2>/dev/null)
            local tmp_restart=$($JQ -r '.internet_manager.restart_on_failure // empty' "$config_file" 2>/dev/null)
            
            [ -n "$tmp_interval" ] && [ "$tmp_interval" != "null" ] && CHECK_INTERVAL=$tmp_interval
            [ -n "$tmp_threshold" ] && [ "$tmp_threshold" != "null" ] && FAIL_THRESHOLD=$tmp_threshold
            [ -n "$tmp_timeout" ] && [ "$tmp_timeout" != "null" ] && TIMEOUT=$tmp_timeout
            [ -n "$tmp_url" ] && [ "$tmp_url" != "null" ] && TEST_URL="$tmp_url"
            [ -n "$tmp_restart" ] && [ "$tmp_restart" != "null" ] && RESTART_ON_FAILURE=$tmp_restart
            
            print_info "[SETUP] Internet Manager enabled from $(basename "$config_file")"
            print_info "[SETUP]   interval=${CHECK_INTERVAL}s, threshold=$FAIL_THRESHOLD, timeout=${TIMEOUT}s"
            print_info "[SETUP]   test_url=$TEST_URL, restart_on_failure=$RESTART_ON_FAILURE"
            break
        fi
    done
    
    # Simpan setting ke file untuk digunakan oleh manager process
    cat > "$MANAGER_CONFIG" << EOF
ENABLED=$MANAGER_ENABLED
CHECK_INTERVAL=$CHECK_INTERVAL
FAIL_THRESHOLD=$FAIL_THRESHOLD
TIMEOUT=$TIMEOUT
TEST_URL=$TEST_URL
RESTART_ON_FAILURE=$RESTART_ON_FAILURE
EOF
}

# -------------------------------------------------------------------
#  Log rotator
# -------------------------------------------------------------------
start_log_rotator() {
    (
        while true; do
            sleep 600
            if [ -f "$LOGFILE" ]; then
                lines=$(busybox wc -l < "$LOGFILE" 2>/dev/null || echo 0)
                size=$(busybox wc -c < "$LOGFILE" 2>/dev/null || echo 0)
                if [ "$lines" -gt 2000 ] || [ "$size" -gt 2097152 ]; then
                    busybox tail -n 1000 "$LOGFILE" > "$LOGFILE.tmp"
                    busybox mv "$LOGFILE.tmp" "$LOGFILE"
                    log_msg "[ROTATE] Log trimmed to 1000 lines"
                fi
            fi
        done
    ) &
    echo $! > "$ROTATE_PIDFILE"
    log_msg "Log rotator started PID=$(cat $ROTATE_PIDFILE)"
}

# -------------------------------------------------------------------
#  Internet Manager (monitors specific aggregator, can be disabled)
# -------------------------------------------------------------------
start_internet_manager() {
    local AGG_PORT="$1"
    
    # Load settings from config
    if [ -f "$MANAGER_CONFIG" ]; then
        . "$MANAGER_CONFIG"
    else
        MANAGER_ENABLED=0
    fi
    
    if [ "$MANAGER_ENABLED" -ne 1 ]; then
        print_info "[INTERNET-MGR] Disabled by config (set internet_manager.enabled=true to activate)"
        return 0
    fi
    
    (
        local fail_count=0
        local recovering=0
        
        print_info "[INTERNET-MGR] Started monitoring aggregator $AGG_PORT"
        print_info "[INTERNET-MGR] Settings: interval=${CHECK_INTERVAL}s, threshold=$FAIL_THRESHOLD, timeout=${TIMEOUT}s"
        
        while true; do
            sleep $CHECK_INTERVAL
            
            if [ ! -f "$PIDFILE" ] || ! pidof clash >/dev/null; then
                print_info "[INTERNET-MGR] QTUN core not running. Exiting."
                exit 0
            fi
            
            # Test internet melalui aggregator
            if $CURL -so /dev/null -x socks5h://127.0.0.1:"$AGG_PORT" \
                --connect-timeout $TIMEOUT --max-time $((TIMEOUT + 5)) \
                "$TEST_URL" 2>/dev/null
            then
                if [ $fail_count -ge $FAIL_THRESHOLD ]; then
                    print_info "[INTERNET-MGR] Connection restored after $fail_count failures."
                fi
                fail_count=0
                recovering=0
            else
                fail_count=$((fail_count + 1))
                print_info "[INTERNET-MGR] Check FAILED ($fail_count/$FAIL_THRESHOLD)"
                
                if [ $fail_count -ge $FAIL_THRESHOLD ] && [ $recovering -eq 0 ]; then
                    recovering=1
                    
                    if [ "$RESTART_ON_FAILURE" -eq 1 ]; then
                        print_info "[INTERNET-MGR] Threshold reached, restarting ril-daemon..."
                        setprop ctl.restart ril-daemon 2>/dev/null || { stop ril-daemon; start ril-daemon; }
                        print_info "[INTERNET-MGR] Waiting 45 seconds for network to stabilize..."
                        sleep 45
                    else
                        print_info "[INTERNET-MGR] Threshold reached but restart_on_failure disabled."
                        sleep 10
                    fi
                    
                    # Reset counter setelah tindakan
                    fail_count=0
                    sleep 5
                    recovering=0
                fi
            fi
        done
    ) &
    local pid=$!
    echo "$pid" > "$INTERNET_MGR_PIDFILE"
    log_msg "Internet Manager started PID=$pid (monitoring port $AGG_PORT)"
}

# -------------------------------------------------------------------
#  Worker Health Check (always active)
# -------------------------------------------------------------------
start_worker_health_check() {
    (
        while true; do
            sleep 10   # interval 10 detik untuk respons cepat
            [ ! -f "$PIDFILE" ] && exit 0
            
            while IFS='|' read -r agg_port config_file; do
                idx=$((agg_port - 7777))
                base_worker=$((1080 + idx * 1000))
                wcount=$($JQ -r '.worker_count' "$config_file" 2>/dev/null)
                [ -z "$wcount" ] || [ "$wcount" = "null" ] && wcount=4
                
                worker_alive=0
                for i in $(busybox seq 0 $((wcount - 1))); do
                    port=$((base_worker + i))
                    if busybox nc -z 127.0.0.1 $port 2>/dev/null; then
                        worker_alive=1
                        break
                    fi
                done
                
                if [ $worker_alive -eq 0 ]; then
                    print_info "[WORKER-CHECK] No live workers for $agg_port -> immediate restart"
                    
                    # Kill instantly
                    for i in $(busybox seq 0 $((wcount - 1))); do
                        port=$((base_worker + i))
                        busybox fuser -k -9 "$port/tcp" 2>/dev/null
                    done
                    busybox fuser -k -9 "$agg_port/tcp" 2>/dev/null
                    killall -9 libuz libload 2>/dev/null
                    sleep 0.3
                    
                    # Restart workers
                    obfs=$($JQ -r '.obfs' "$config_file" 2>/dev/null)
                    for i in $(busybox seq 0 $((wcount - 1))); do
                        port=$((base_worker + i))
                        json=$($JQ --arg port "$port" '.socks5.listen = "127.0.0.1:\($port)"' "$config_file")
                        $BINDIR/libuz -s "$obfs" --config "$json" >> "$LOGFILE" 2>&1 &
                    done
                    sleep 0.3
                    
                    # Restart aggregator
                    tunnel_list=""
                    for i in $(busybox seq 0 $((wcount - 1))); do
                        tunnel_list="$tunnel_list 127.0.0.1:$((base_worker + i))"
                    done
                    $BINDIR/libload -lport "$agg_port" -tunnel $tunnel_list >> "$LOGFILE" 2>&1 &
                    
                    sleep 1
                    print_info "[WORKER-CHECK] Aggregator $agg_port restarted"
                fi
            done < "$AGGREGATOR_MAP"
        done
    ) &
    local pid=$!
    echo "$pid" > "$WORKER_CHECK_PIDFILE"
    log_msg "Worker Health Check started PID=$pid (interval 10s)"
}

# -------------------------------------------------------------------
#  Process a single config
# -------------------------------------------------------------------
process_config() {
    local CONFIG_FILE="$1"
    local CONFIG_INDEX="$2"
    local BASE_WORKER_PORT=$((1080 + CONFIG_INDEX * 1000))
    local AGG_PORT=$((7777 + CONFIG_INDEX))
    local PROXY_NAME=$(basename "$CONFIG_FILE" .json)
    
    print_info "Processing config: $PROXY_NAME"
    log_msg "Config $PROXY_NAME: workers $BASE_WORKER_PORT, agg $AGG_PORT"
    
    local SERVER=$($JQ -r '.server' "$CONFIG_FILE" 2>/dev/null)
    local IP_ONLY=$(echo "$SERVER" | cut -d':' -f1)
    local OBFS=$($JQ -r '.obfs' "$CONFIG_FILE" 2>/dev/null)
    local WORKER_COUNT=$($JQ -r '.worker_count' "$CONFIG_FILE" 2>/dev/null)
    
    [ -z "$SERVER" ] || [ "$SERVER" = "null" ] && { print_info "[ERROR] No server in $PROXY_NAME"; return 1; }
    [ -z "$WORKER_COUNT" ] || [ "$WORKER_COUNT" = "null" ] || [ "$WORKER_COUNT" -lt 1 ] && WORKER_COUNT=4
    [ -z "$IP_ONLY" ] || [ "$IP_ONLY" = "null" ] && { print_info "[ERROR] Invalid server IP in $PROXY_NAME"; return 1; }
    
    SERVER_IPS="${SERVER_IPS}$IP_ONLY "
    
    # Start workers
    local TUNNEL_LIST=""
    for i in $(busybox seq 0 $((WORKER_COUNT - 1))); do
        local PORT=$((BASE_WORKER_PORT + i))
        TUNNEL_LIST="$TUNNEL_LIST 127.0.0.1:$PORT"
        local JSON_DATA=$($JQ --arg port "$PORT" '.socks5.listen = "127.0.0.1:\($port)"' "$CONFIG_FILE")
        $BINDIR/libuz -s "$OBFS" --config "$JSON_DATA" >> "$LOGFILE" 2>&1 &
        sleep 0.1
    done
    
    sleep 1
    if ! pidof libuz >/dev/null; then
        print_info "  Workers FAILED"
        return 1
    fi
    print_info "  Workers started [OK]"
    
    # Start aggregator
    print_info "  Starting aggregator on port $AGG_PORT..."
    $BINDIR/libload -lport "$AGG_PORT" -tunnel $TUNNEL_LIST >> "$LOGFILE" 2>&1 &
    sleep 1
    if pidof libload >/dev/null; then
        print_info "  Aggregator on $AGG_PORT started [OK]"
        echo "$AGG_PORT|$CONFIG_FILE" >> "$AGGREGATOR_MAP"
        echo "$PROXY_NAME|$AGG_PORT" >> "$RUNDIR/aggregators.list"
    else
        print_info "  Aggregator FAILED"
        return 1
    fi
    return 0
}

# -------------------------------------------------------------------
#  Generate Clash config
# -------------------------------------------------------------------
generate_clash_config() {
    local CONF_CLASH="$CLASHDIR/config.yaml"
    local TPL_CLASH="$CLASHDIR/template-config.yaml"
    [ ! -f "$TPL_CLASH" ] && cleanup_fail "Template $TPL_CLASH missing"
    
    cp "$TPL_CLASH" "$CONF_CLASH"
    
    $YQ -i 'del(.proxies[] | select(.type == "socks5"))' "$CONF_CLASH"
    $YQ -i 'del(.proxy-groups[] | select(.name == "AUTO" or .name == "Keep-Alive"))' "$CONF_CLASH"
    
    local AGG_LIST=$(cat "$RUNDIR/aggregators.list" 2>/dev/null)
    local PROXY_NAMES=""
    for agg in $AGG_LIST; do
        local NAME=$(echo "$agg" | cut -d'|' -f1)
        local PORT=$(echo "$agg" | cut -d'|' -f2)
        $YQ -i ".proxies += [{\"name\":\"$NAME\",\"type\":\"socks5\",\"server\":\"127.0.0.1\",\"port\":$PORT,\"udp\":true}]" "$CONF_CLASH"
        PROXY_NAMES="$PROXY_NAMES,\"$NAME\""
    done
    PROXY_NAMES="${PROXY_NAMES#,}"
    
    $YQ -i ".proxy-groups += [{\"name\":\"AUTO\",\"type\":\"select\",\"proxies\":[$PROXY_NAMES,\"DIRECT\"]}]" "$CONF_CLASH"
    $YQ -i ".proxy-groups += [{\"name\":\"Keep-Alive\",\"type\":\"url-test\",\"proxies\":[$PROXY_NAMES],\"url\":\"http://www.gstatic.com/generate_204\",\"interval\":20,\"tolerance\":500}]" "$CONF_CLASH"
    
    for ip in $SERVER_IPS; do
        $YQ -i ".dns.fake-ip-filter += \"$ip\"" "$CONF_CLASH"
        $YQ -i ".rules = [\"IP-CIDR,$ip/32,DIRECT\"] + .rules" "$CONF_CLASH"
    done
    
    print_info "Clash configuration updated [OK]"
}

# -------------------------------------------------------------------
#  Main start
# -------------------------------------------------------------------
start() {
    echo "--- QTUN START: $(date) ---" > "$LOGFILE"
    log_msg "Starting QTUN v$VERSION with Configurable Internet Manager"
    
    for bin in libuz libload clash curl yq jq; do
        [ ! -f "$BINDIR/$bin" ] && cleanup_fail "Binary $BINDIR/$bin missing"
        chmod +x "$BINDIR/$bin" 2>/dev/null
    done
    
    killall -9 libuz libload clash 2>/dev/null
    sleep 0.5
    show_banner
    
    # Load internet manager settings dari config.json
    load_manager_settings
    
    rm -f "$RUNDIR/aggregators.list" "$AGGREGATOR_MAP"
    rm -rf "$FAILCOUNT_DIR" && mkdir -p "$FAILCOUNT_DIR"
    SERVER_IPS=""
    
    CONFIG_INDEX=0
    for config_file in $(ls "$CONFDIR"/*.json 2>/dev/null | grep -v "users\.json$"); do
        if process_config "$config_file" $CONFIG_INDEX; then
            CONFIG_INDEX=$((CONFIG_INDEX + 1))
        fi
    done
    
    if [ ! -f "$RUNDIR/aggregators.list" ]; then
        cleanup_fail "No aggregator could be started."
    fi
    
    generate_clash_config
    
    print_info "Starting Clash core..."
    GID_CLASH=3004
    setuidgid 0:$GID_CLASH $BINDIR/clash -d "$CLASHDIR" -f "$CLASHDIR/config.yaml" >> "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 2
    if ! pidof clash >/dev/null; then
        cleanup_fail "Clash failed to start"
    fi
    print_info "Clash started (PID $(cat $PIDFILE)) [OK]"
    
    print_info "Verifying aggregators..."
    FIRST_AGG_PORT=""
    while IFS='|' read -r name port; do
        if [ -z "$FIRST_AGG_PORT" ]; then
            FIRST_AGG_PORT="$port"
        fi
        if $CURL -so /dev/null -x socks5h://127.0.0.1:"$port" --connect-timeout 2 http://www.google.com 2>/dev/null; then
            print_info "  $name -> socks5://127.0.0.1:$port [OK]"
        else
            print_info "  $name -> socks5://127.0.0.1:$port [WARN] Not responding yet"
        fi
    done < "$RUNDIR/aggregators.list"
    
    echo ""
    echo "=========================================="
    echo "   QTUN Multi-Config is ONLINE"
    if [ "$MANAGER_ENABLED" -eq 1 ]; then
        echo "   Internet Manager: ENABLED"
        echo "   (check every ${CHECK_INTERVAL}s, threshold $FAIL_THRESHOLD)"
    else
        echo "   Internet Manager: DISABLED"
    fi
    echo "=========================================="
    echo " Clash Mixed Port: 127.0.0.1:7890"
    echo " Selector: AUTO"
    log_msg "[SUCCESS] System online with $(wc -l < "$RUNDIR/aggregators.list") aggregators."
    
    start_worker_health_check
    start_internet_manager "$FIRST_AGG_PORT"
    start_log_rotator
}

# -------------------------------------------------------------------
#  Stop
# -------------------------------------------------------------------
stop() {
    print_info "Stopping QTUN services..."
    for pidf in "$MANAGER_PIDFILE" "$WORKER_CHECK_PIDFILE" "$ROTATE_PIDFILE" "$INTERNET_MGR_PIDFILE"; do
        [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null && rm -f "$pidf"
    done
    killall -9 libuz libload clash 2>/dev/null
    rm -f "$PIDFILE" "$MANAGER_CONFIG"
    print_info "All services stopped [OK]"
    log_msg "[STOP] Services stopped."
}

# -------------------------------------------------------------------
#  Status
# -------------------------------------------------------------------
status() {
    echo "-------------- QTUN Status --------------"
    echo " Binary Dir        : $BINDIR"
    echo " Workers           : $(pidof libuz | wc -w 2>/dev/null || echo 0) running"
    echo " Aggregator(s)     : $(pidof libload >/dev/null && echo "Running" || echo "Stopped")"
    echo " Clash             : $(pidof clash >/dev/null && echo "Running" || echo "Stopped")"
    [ -f "$PIDFILE" ] && echo " Clash PID         : $(cat $PIDFILE)" || echo " PID File          : missing"
    [ -f "$MANAGER_PIDFILE" ] && echo " Aggregator Manager PID: $(cat $MANAGER_PIDFILE)" || echo " Aggregator Manager: Not running"
    [ -f "$WORKER_CHECK_PIDFILE" ] && echo " Worker Health PID : $(cat $WORKER_CHECK_PIDFILE)" || echo " Worker Health     : Not running"
    [ -f "$INTERNET_MGR_PIDFILE" ] && echo " Internet Manager PID: $(cat $INTERNET_MGR_PIDFILE)" || echo " Internet Manager  : Not running"
    [ -f "$ROTATE_PIDFILE" ] && echo " Log Rotator PID   : $(cat $ROTATE_PIDFILE)" || echo " Log Rotator       : Not running"
    echo " Log file          : $LOGFILE (rotated)"
    
    if [ -f "$MANAGER_CONFIG" ]; then
        . "$MANAGER_CONFIG"
        echo " Internet Manager  : $([ "$ENABLED" -eq 1 ] && echo "Enabled" || echo "Disabled")"
        [ "$ENABLED" -eq 1 ] && echo "   Interval: ${CHECK_INTERVAL}s, Threshold: $FAIL_THRESHOLD"
    fi
    
    echo " Aggregators monitored:"
    while IFS='|' read -r port config; do
        echo "   Port $port -> $(basename "$config")"
    done < "$AGGREGATOR_MAP" 2>/dev/null
    echo "------------------------------------------"
}

# -------------------------------------------------------------------
#  Command line
# -------------------------------------------------------------------
case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        echo ""
        echo "Internet Manager configuration in config.json:"
        echo '  "internet_manager": {'
        echo '    "enabled": true,'
        echo '    "check_interval": 15,'
        echo '    "fail_threshold": 2,'
        echo '    "timeout": 8,'
        echo '    "test_url": "http://www.google.com",'
        echo '    "restart_on_failure": true'
        echo '  }'
        exit 1
        ;;
esac