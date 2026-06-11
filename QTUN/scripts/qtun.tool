#!/system/bin/sh
# QTUN Core v8 - Complete Upgrade with Working Internet Manager

MODDIR="/data/adb/QTUN"
CONFDIR="$MODDIR/config"
RUNDIR="$MODDIR/run"
CLASHDIR="$MODDIR/clash"
LOGFILE="$RUNDIR/run.log"
AGGREGATOR_MAP="$RUNDIR/aggregator_config.map"
FAILCOUNT_DIR="$RUNDIR/failcounts"
MANAGER_CONFIG="$RUNDIR/manager_config"

# Default values
DEFAULT_CHECK_INTERVAL=20
DEFAULT_FAIL_THRESHOLD=3
DEFAULT_TIMEOUT=10
DEFAULT_TEST_URL="http://www.google.com"
DEFAULT_WORKER_CHECK_INTERVAL=8
DEFAULT_AGGREGATOR_MANAGER_ENABLED=0

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
AGG_MANAGER_PIDFILE="$RUNDIR/aggregator_manager.pid"
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
    for pidf in "$AGG_MANAGER_PIDFILE" "$WORKER_CHECK_PIDFILE" "$INTERNET_MGR_PIDFILE"; do
        [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null
    done
    killall -9 libuz libload clash 2>/dev/null
    rm -f "$PIDFILE" "$AGG_MANAGER_PIDFILE" "$WORKER_CHECK_PIDFILE" "$INTERNET_MGR_PIDFILE"
    exit 1
}

show_banner() {
    echo "=========================================="
    echo "      QTUN ZIVPN SYSTEM v$VERSION"
    echo "   Complete Manager Suite"
    echo "=========================================="
    echo ""
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
#  Parse boolean dari JSON (true/false/1/0/yes/no)
# -------------------------------------------------------------------
parse_boolean() {
    local val="$1"
    case "$val" in
        true|1|yes|on|enabled) echo "1" ;;
        false|0|no|off|disabled) echo "0" ;;
        *) echo "0" ;;
    esac
}

# -------------------------------------------------------------------
#  Load internet manager settings from config files
# -------------------------------------------------------------------
load_manager_settings() {
    MANAGER_ENABLED=0
    CHECK_INTERVAL=$DEFAULT_CHECK_INTERVAL
    FAIL_THRESHOLD=$DEFAULT_FAIL_THRESHOLD
    TIMEOUT=$DEFAULT_TIMEOUT
    TEST_URL="$DEFAULT_TEST_URL"
    RESTART_ON_FAILURE=1
    AGGREGATOR_MANAGER_ENABLED=$DEFAULT_AGGREGATOR_MANAGER_ENABLED
    
    for config_file in $(ls "$CONFDIR"/*.json 2>/dev/null | grep -v "users\.json$"); do
        # Cek apakah ada field internet_manager
        local has_manager=$($JQ -r '.internet_manager // empty' "$config_file" 2>/dev/null)
        if [ -n "$has_manager" ] && [ "$has_manager" != "null" ] && [ "$has_manager" != "" ]; then
            local enabled=$($JQ -r '.internet_manager.enabled // false' "$config_file" 2>/dev/null)
            
            if [ "$enabled" = "true" ]; then
                MANAGER_ENABLED=1
                
                # Ambil nilai dengan default
                local tmp_interval=$($JQ -r '.internet_manager.check_interval // 20' "$config_file" 2>/dev/null)
                local tmp_threshold=$($JQ -r '.internet_manager.fail_threshold // 3' "$config_file" 2>/dev/null)
                local tmp_timeout=$($JQ -r '.internet_manager.timeout // 10' "$config_file" 2>/dev/null)
                local tmp_url=$($JQ -r '.internet_manager.test_url // "http://www.google.com"' "$config_file" 2>/dev/null)
                local tmp_restart=$($JQ -r '.internet_manager.restart_on_failure // true' "$config_file" 2>/dev/null)
                local tmp_agg_manager=$($JQ -r '.internet_manager.aggregator_manager // false' "$config_file" 2>/dev/null)
                
                # Validasi numerik
                echo "$tmp_interval" | grep -qE '^[0-9]+$' && CHECK_INTERVAL=$tmp_interval
                echo "$tmp_threshold" | grep -qE '^[0-9]+$' && FAIL_THRESHOLD=$tmp_threshold
                echo "$tmp_timeout" | grep -qE '^[0-9]+$' && TIMEOUT=$tmp_timeout
                
                [ -n "$tmp_url" ] && [ "$tmp_url" != "null" ] && [ "$tmp_url" != "" ] && TEST_URL="$tmp_url"
                
                RESTART_ON_FAILURE=$(parse_boolean "$tmp_restart")
                AGGREGATOR_MANAGER_ENABLED=$(parse_boolean "$tmp_agg_manager")
                
                print_info "[SETUP] Internet Manager: ENABLED (from $(basename "$config_file"))"
                print_info "[SETUP]   check_interval=${CHECK_INTERVAL}s, fail_threshold=$FAIL_THRESHOLD, timeout=${TIMEOUT}s"
                print_info "[SETUP]   test_url=$TEST_URL"
                print_info "[SETUP]   restart_on_failure=$RESTART_ON_FAILURE"
                print_info "[SETUP]   aggregator_manager=$AGGREGATOR_MANAGER_ENABLED"
                break
            fi
        fi
    done
    
    # Simpan ke file
    cat > "$MANAGER_CONFIG" << EOF
MANAGER_ENABLED=$MANAGER_ENABLED
CHECK_INTERVAL=$CHECK_INTERVAL
FAIL_THRESHOLD=$FAIL_THRESHOLD
TIMEOUT=$TIMEOUT
TEST_URL=$TEST_URL
RESTART_ON_FAILURE=$RESTART_ON_FAILURE
AGGREGATOR_MANAGER_ENABLED=$AGGREGATOR_MANAGER_ENABLED
EOF
}

# -------------------------------------------------------------------
#  FAST RESTART for a specific aggregator
# -------------------------------------------------------------------
restart_aggregator_workers() {
    local AGG_PORT="$1"
    local REASON="$2"
    
    local CONFIG_INDEX=$((AGG_PORT - 7777))
    [ $CONFIG_INDEX -lt 0 ] && { print_info "[RESTART] Invalid aggregator port $AGG_PORT"; return 1; }
    
    local CONFIG_FILE=$(grep "^$AGG_PORT|" "$AGGREGATOR_MAP" 2>/dev/null | cut -d'|' -f2)
    [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ] && { print_info "[RESTART] No config for port $AGG_PORT"; return 1; }
    
    print_info "[RESTART] Fast restart aggregator $AGG_PORT (reason: $REASON)"
    
    local BASE_WORKER_PORT=$((1080 + CONFIG_INDEX * 1000))
    local WORKER_COUNT=$($JQ -r '.worker_count' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$WORKER_COUNT" ] || [ "$WORKER_COUNT" = "null" ] || [ "$WORKER_COUNT" -lt 1 ] && WORKER_COUNT=4
    local OBFS=$($JQ -r '.obfs' "$CONFIG_FILE" 2>/dev/null)
    
    # Kill instantly
    for i in $(busybox seq 0 $((WORKER_COUNT - 1))); do
        local PORT=$((BASE_WORKER_PORT + i))
        busybox fuser -k -9 "$PORT/tcp" 2>/dev/null
    done
    busybox fuser -k -9 "$AGG_PORT/tcp" 2>/dev/null
    killall -9 libuz libload 2>/dev/null
    sleep 0.3
    
    # Start workers
    for i in $(busybox seq 0 $((WORKER_COUNT - 1))); do
        local PORT=$((BASE_WORKER_PORT + i))
        local JSON_DATA=$($JQ --arg port "$PORT" '.socks5.listen = "127.0.0.1:\($port)"' "$CONFIG_FILE")
        $BINDIR/libuz -s "$OBFS" --config "$JSON_DATA" >> "$LOGFILE" 2>&1 &
    done
    sleep 0.3
    
    # Start aggregator
    local TUNNEL_LIST=""
    for i in $(busybox seq 0 $((WORKER_COUNT - 1))); do
        TUNNEL_LIST="$TUNNEL_LIST 127.0.0.1:$((BASE_WORKER_PORT + i))"
    done
    $BINDIR/libload -lport "$AGG_PORT" -tunnel $TUNNEL_LIST >> "$LOGFILE" 2>&1 &
    
    sleep 0.5
    if busybox nc -z 127.0.0.1 "$AGG_PORT" 2>/dev/null; then
        print_info "[RESTART] Aggregator $AGG_PORT restored"
    else
        print_info "[RESTART] WARNING: Aggregator $AGG_PORT may still be down"
    fi
    return 0
}

# -------------------------------------------------------------------
#  Worker Health Check (always active, very responsive)
# -------------------------------------------------------------------
start_worker_health_check() {
    (
        local CHECK_INTERVAL=$DEFAULT_WORKER_CHECK_INTERVAL
        print_info "[WORKER-CHECK] Started (interval ${CHECK_INTERVAL}s) - checks worker ports directly"
        
        while true; do
            sleep $CHECK_INTERVAL
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
                    print_info "[WORKER-CHECK] No live workers for $agg_port -> restarting"
                    restart_aggregator_workers "$agg_port" "no live workers"
                    sleep 2
                fi
            done < "$AGGREGATOR_MAP"
        done
    ) &
    local pid=$!
    echo "$pid" > "$WORKER_CHECK_PIDFILE"
    log_msg "Worker Health Check started PID=$pid"
}

# -------------------------------------------------------------------
#  Aggregator Manager (optional, checks via HTTP)
# -------------------------------------------------------------------
start_aggregator_manager() {
    (
        # Read settings
        if [ -f "$MANAGER_CONFIG" ]; then
            AGG_MGR_ENABLED=$(grep "^AGGREGATOR_MANAGER_ENABLED=" "$MANAGER_CONFIG" | cut -d'=' -f2)
            CHECK_INT=$(grep "^CHECK_INTERVAL=" "$MANAGER_CONFIG" | cut -d'=' -f2)
            FAIL_THRESH=$(grep "^FAIL_THRESHOLD=" "$MANAGER_CONFIG" | cut -d'=' -f2)
            TEST_URL=$(grep "^TEST_URL=" "$MANAGER_CONFIG" | cut -d'=' -f2-)
            TIMEOUT_VAL=$(grep "^TIMEOUT=" "$MANAGER_CONFIG" | cut -d'=' -f2)
        else
            AGG_MGR_ENABLED=0
            CHECK_INT=30
            FAIL_THRESH=3
            TEST_URL="http://www.google.com"
            TIMEOUT_VAL=10
        fi
        
        if [ "$AGG_MGR_ENABLED" != "1" ]; then
            print_info "[AGG-MANAGER] Disabled (set aggregator_manager: true in config to enable)"
            return 0
        fi
        
        # Read aggregator ports
        AGG_PORTS=""
        while IFS='|' read -r port config; do
            AGG_PORTS="$AGG_PORTS $port"
            rm -f "$FAILCOUNT_DIR/$port"
        done < "$AGGREGATOR_MAP"
        
        [ -z "$AGG_PORTS" ] && { print_info "[AGG-MANAGER] No aggregators to monitor. Exiting."; exit 1; }
        print_info "[AGG-MANAGER] Started monitoring: $AGG_PORTS (interval ${CHECK_INT}s, threshold $FAIL_THRESH)"
        
        while true; do
            sleep $CHECK_INT
            [ ! -f "$PIDFILE" ] && exit 0
            
            for port in $AGG_PORTS; do
                if $CURL -so /dev/null -x socks5h://127.0.0.1:"$port" \
                    --connect-timeout $TIMEOUT_VAL --max-time $((TIMEOUT_VAL + 5)) \
                    "$TEST_URL" 2>/dev/null
                then
                    # Success, reset counter
                    [ -f "$FAILCOUNT_DIR/$port" ] && rm -f "$FAILCOUNT_DIR/$port"
                else
                    # Failed, increment counter
                    COUNT=$(cat "$FAILCOUNT_DIR/$port" 2>/dev/null || echo 0)
                    COUNT=$((COUNT + 1))
                    echo "$COUNT" > "$FAILCOUNT_DIR/$port"
                    
                    if [ $COUNT -ge $FAIL_THRESH ]; then
                        print_info "[AGG-MANAGER] Aggregator $port failed $COUNT times -> restarting"
                        restart_aggregator_workers "$port" "HTTP failed $COUNT times"
                        rm -f "$FAILCOUNT_DIR/$port"
                        sleep 3
                    else
                        print_info "[AGG-MANAGER] Aggregator $port failed ($COUNT/$FAIL_THRESH)"
                    fi
                fi
            done
        done
    ) &
    local pid=$!
    echo "$pid" > "$AGG_MANAGER_PIDFILE"
    log_msg "Aggregator Manager started PID=$pid"
}

# -------------------------------------------------------------------
#  Internet Manager (monitors connectivity, can restart ril-daemon)
# -------------------------------------------------------------------
start_internet_manager() {
    local AGG_PORT="$1"
    
    if [ -f "$MANAGER_CONFIG" ]; then
        MANAGER_ENABLED=$(grep "^MANAGER_ENABLED=" "$MANAGER_CONFIG" | cut -d'=' -f2)
        CHECK_INTERVAL=$(grep "^CHECK_INTERVAL=" "$MANAGER_CONFIG" | cut -d'=' -f2)
        FAIL_THRESHOLD=$(grep "^FAIL_THRESHOLD=" "$MANAGER_CONFIG" | cut -d'=' -f2)
        TIMEOUT=$(grep "^TIMEOUT=" "$MANAGER_CONFIG" | cut -d'=' -f2)
        TEST_URL=$(grep "^TEST_URL=" "$MANAGER_CONFIG" | cut -d'=' -f2-)
        RESTART_ON_FAILURE=$(grep "^RESTART_ON_FAILURE=" "$MANAGER_CONFIG" | cut -d'=' -f2)
    else
        MANAGER_ENABLED=0
        CHECK_INTERVAL=20
        FAIL_THRESHOLD=3
        TIMEOUT=10
        TEST_URL="http://www.google.com"
        RESTART_ON_FAILURE=1
    fi
    
    [ -z "$RESTART_ON_FAILURE" ] && RESTART_ON_FAILURE=1
    
    if [ "$MANAGER_ENABLED" != "1" ]; then
        print_info "[INTERNET-MGR] Disabled (set internet_manager.enabled: true in config)"
        echo "disabled" > "$INTERNET_MGR_PIDFILE"
        return 0
    fi
    
    (
        local fail_count=0
        local recovering=0
        
        print_info "[INTERNET-MGR] Started monitoring via port $AGG_PORT"
        print_info "[INTERNET-MGR] Settings: interval=${CHECK_INTERVAL}s, threshold=$FAIL_THRESHOLD, timeout=${TIMEOUT}s"
        print_info "[INTERNET-MGR] restart_on_failure = $RESTART_ON_FAILURE"
        print_info "[INTERNET-MGR] test_url = $TEST_URL"
        
        while true; do
            sleep $CHECK_INTERVAL
            
            if [ ! -f "$PIDFILE" ] || ! pidof clash >/dev/null; then
                print_info "[INTERNET-MGR] QTUN core not running. Exiting."
                exit 0
            fi
            
            # Test internet through aggregator
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
                        print_info "[INTERNET-MGR] Threshold reached! Restarting ril-daemon..."
                        setprop ctl.restart ril-daemon 2>/dev/null || { stop ril-daemon; start ril-daemon; }
                        print_info "[INTERNET-MGR] Waiting 45 seconds for network to stabilize..."
                        sleep 45
                    else
                        print_info "[INTERNET-MGR] Threshold reached but restart_on_failure=DISABLED (no action)"
                        sleep 30
                    fi
                    
                    fail_count=0
                    sleep 5
                    recovering=0
                fi
            fi
        done
    ) &
    local pid=$!
    echo "$pid" > "$INTERNET_MGR_PIDFILE"
    log_msg "Internet Manager started PID=$pid (restart_on_failure=$RESTART_ON_FAILURE)"
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
    log_msg "Starting QTUN v$VERSION"
    
    for bin in libuz libload clash curl yq jq; do
        [ ! -f "$BINDIR/$bin" ] && cleanup_fail "Binary $BINDIR/$bin missing"
        chmod +x "$BINDIR/$bin" 2>/dev/null
    done
    
    killall -9 libuz libload clash 2>/dev/null
    sleep 0.5
    show_banner
    
    # Load settings from config.json
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
    
    # Get first aggregator port for internet manager
    FIRST_AGG_PORT=$(head -n1 "$RUNDIR/aggregators.list" 2>/dev/null | cut -d'|' -f2)
    
    print_info "Verifying aggregators..."
    while IFS='|' read -r name port; do
        if $CURL -so /dev/null -x socks5h://127.0.0.1:"$port" --connect-timeout 2 http://www.google.com 2>/dev/null; then
            print_info "  $name -> socks5://127.0.0.1:$port [OK]"
        else
            print_info "  $name -> socks5://127.0.0.1:$port [WARN]"
        fi
    done < "$RUNDIR/aggregators.list"
    
    echo ""
    echo "=========================================="
    echo "   QTUN Multi-Config is ONLINE"
    echo "=========================================="
    echo " Clash Mixed Port: 127.0.0.1:7890"
    echo " Selector: AUTO"
    
    if [ "$MANAGER_ENABLED" -eq 1 ]; then
        echo " Internet Manager: ENABLED"
        echo "   restart_on_failure: $([ "$RESTART_ON_FAILURE" -eq 1 ] && echo "YES" || echo "NO")"
    else
        echo " Internet Manager: DISABLED"
    fi
    echo " Worker Health Check: ACTIVE (every ${DEFAULT_WORKER_CHECK_INTERVAL}s)"
    echo "=========================================="
    
    log_msg "[SUCCESS] System online with $(wc -l < "$RUNDIR/aggregators.list") aggregators"
    
    # Start all managers
    start_worker_health_check
    start_aggregator_manager
    start_internet_manager "$FIRST_AGG_PORT"
    start_log_rotator
}

# -------------------------------------------------------------------
#  Stop
# -------------------------------------------------------------------
stop() {
    print_info "Stopping QTUN services..."
    for pidf in "$AGG_MANAGER_PIDFILE" "$WORKER_CHECK_PIDFILE" "$ROTATE_PIDFILE" "$INTERNET_MGR_PIDFILE"; do
        if [ -f "$pidf" ]; then
            local pid=$(cat "$pidf" 2>/dev/null)
            [ -n "$pid" ] && [ "$pid" != "disabled" ] && kill "$pid" 2>/dev/null
            rm -f "$pidf"
        fi
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
    echo ""
    
    [ -f "$PIDFILE" ] && echo " Clash PID         : $(cat $PIDFILE)"
    
    if [ -f "$WORKER_CHECK_PIDFILE" ]; then
        local wpid=$(cat "$WORKER_CHECK_PIDFILE")
        [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null && echo " Worker Health     : Running (PID $wpid)" || echo " Worker Health     : Stopped"
    fi
    
    if [ -f "$INTERNET_MGR_PIDFILE" ]; then
        local ipid=$(cat "$INTERNET_MGR_PIDFILE")
        if [ "$ipid" = "disabled" ]; then
            echo " Internet Manager  : Disabled"
        elif [ -n "$ipid" ] && kill -0 "$ipid" 2>/dev/null; then
            echo " Internet Manager  : Running (PID $ipid)"
        else
            echo " Internet Manager  : Stopped"
        fi
    fi
    
    if [ -f "$AGG_MANAGER_PIDFILE" ]; then
        local apid=$(cat "$AGG_MANAGER_PIDFILE")
        if [ -n "$apid" ] && kill -0 "$apid" 2>/dev/null; then
            echo " Aggregator Manager: Running (PID $apid)"
        else
            echo " Aggregator Manager: Stopped"
        fi
    fi
    
    echo ""
    if [ -f "$MANAGER_CONFIG" ]; then
        MANAGER_ENABLED=$(grep "^MANAGER_ENABLED=" "$MANAGER_CONFIG" | cut -d'=' -f2)
        RESTART_ON_FAILURE=$(grep "^RESTART_ON_FAILURE=" "$MANAGER_CONFIG" | cut -d'=' -f2)
        echo " Internet Manager Config:"
        echo "   Enabled        : $([ "$MANAGER_ENABLED" -eq 1 ] && echo "Yes" || echo "No")"
        echo "   Restart on fail: $([ "$RESTART_ON_FAILURE" -eq 1 ] && echo "Yes" || echo "No")"
    fi
    
    echo ""
    echo " Aggregators:"
    while IFS='|' read -r port config; do
        echo "   Port $port -> $(basename "$config")"
    done < "$AGGREGATOR_MAP" 2>/dev/null
    echo " Log file          : $LOGFILE"
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
        echo "Config.json example:"
        echo '{'
        echo '  "server": "isiserver:6000-19999",'
        echo '  "obfs": "secret",'
        echo '  "auth": "password",'
        echo '  "worker_count": 4,'
        echo '  "internet_manager": {'
        echo '    "enabled": true,'
        echo '    "check_interval": 20,'
        echo '    "fail_threshold": 3,'
        echo '    "timeout": 10,'
        echo '    "test_url": "http://www.google.com",'
        echo '    "restart_on_failure": true,'
        echo '    "aggregator_manager": false'
        echo '  }'
        echo '}'
        exit 1
        ;;
esac