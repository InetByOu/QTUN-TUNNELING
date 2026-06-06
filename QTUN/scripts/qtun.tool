#!/system/bin/sh
# QTUN Core Tool v3 - Aggregator Manager (No bash-isms)

MODDIR="/data/adb/QTUN"
CONFDIR="$MODDIR/config"
RUNDIR="$MODDIR/run"
SCRIPTDIR="$MODDIR/scripts"
CLASHDIR="$MODDIR/clash"
LOGFILE="$RUNDIR/run.log"
AGGREGATOR_MAP="$RUNDIR/aggregator_config.map"
FAILCOUNT_DIR="$RUNDIR/failcounts"

# -------------------------------------------------------------------
#  Setup environment & binaries
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
WORKER_MONITOR_PIDFILE="$RUNDIR/worker_monitor.pid"
ROTATE_PIDFILE="$RUNDIR/log_rotate.pid"

VERSION=$(grep "^version=" "$MODDIR/../qtun_tunneling/module.prop" 2>/dev/null | cut -d= -f2)
[ -z "$VERSION" ] && VERSION="unknown"

mkdir -p "$RUNDIR" "$FAILCOUNT_DIR"

# -------------------------------------------------------------------
#  Logging functions
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
    kill "$WORKER_MONITOR_PID" 2>/dev/null
    killall libuz libload clash 2>/dev/null
    rm -f "$PIDFILE" "$MANAGER_PIDFILE" "$WORKER_MONITOR_PIDFILE"
    exit 1
}

show_banner() {
    echo "=========================================="
    echo "         QTUN ZIVPN SYSTEM v$VERSION"
    echo "         Aggregator Manager Active"
    echo "=========================================="
    echo ""
}

# -------------------------------------------------------------------
#  Log rotator: every 10 minutes, keep last 1000 lines if too big
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
#  Helper: get/set fail count for an aggregator port
# -------------------------------------------------------------------
get_fail_count() {
    local port="$1"
    local f="$FAILCOUNT_DIR/$port"
    if [ -f "$f" ]; then
        cat "$f" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

set_fail_count() {
    local port="$1"
    local count="$2"
    echo "$count" > "$FAILCOUNT_DIR/$port"
}

reset_fail_count() {
    local port="$1"
    rm -f "$FAILCOUNT_DIR/$port"
}

# -------------------------------------------------------------------
#  Restart workers & aggregator for a specific config
# -------------------------------------------------------------------
restart_aggregator_workers() {
    local AGG_PORT="$1"
    local REASON="$2"
    
    # Find config index from port
    local CONFIG_INDEX=$((AGG_PORT - 7777))
    if [ $CONFIG_INDEX -lt 0 ]; then
        print_info "[AGG-MANAGER] Invalid aggregator port $AGG_PORT"
        return 1
    fi
    
    # Get config file from mapping
    local CONFIG_FILE=$(grep "^$AGG_PORT|" "$AGGREGATOR_MAP" 2>/dev/null | cut -d'|' -f2)
    if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
        print_info "[AGG-MANAGER] No config found for aggregator port $AGG_PORT"
        return 1
    fi
    
    print_info "[AGG-MANAGER] Restarting workers for aggregator $AGG_PORT (reason: $REASON)"
    
    local BASE_WORKER_PORT=$((1080 + CONFIG_INDEX * 1000))
    local WORKER_COUNT=$($JQ -r '.worker_count' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$WORKER_COUNT" ] || [ "$WORKER_COUNT" = "null" ] || [ "$WORKER_COUNT" -lt 1 ] && WORKER_COUNT=4
    local OBFS=$($JQ -r '.obfs' "$CONFIG_FILE" 2>/dev/null)
    
    # Kill workers in this port range (by killing libuz processes that listen on those ports)
    for i in $(busybox seq 0 $((WORKER_COUNT - 1))); do
        local PORT=$((BASE_WORKER_PORT + i))
        local WPID=$(busybox netstat -tulnp 2>/dev/null | grep ":$PORT " | grep -o '[0-9]\+/libuz' | cut -d'/' -f1)
        [ -n "$WPID" ] && kill "$WPID" 2>/dev/null
    done
    # Also kill any libuz that might still hold those ports (broader kill via fuser)
    for i in $(busybox seq 0 $((WORKER_COUNT - 1))); do
        busybox fuser -k "$((BASE_WORKER_PORT + i))/tcp" 2>/dev/null
    done
    sleep 2
    
    # Restart workers
    for i in $(busybox seq 0 $((WORKER_COUNT - 1))); do
        local PORT=$((BASE_WORKER_PORT + i))
        local JSON_DATA=$($JQ --arg port "$PORT" '.socks5.listen = "127.0.0.1:\($port)"' "$CONFIG_FILE")
        $BINDIR/libuz -s "$OBFS" --config "$JSON_DATA" >> "$LOGFILE" 2>&1 &
        sleep 0.2
    done
    sleep 3
    
    # Restart aggregator (libload) for this port
    local AGG_PID=$(busybox netstat -tulnp 2>/dev/null | grep ":$AGG_PORT " | grep -o '[0-9]\+/libload' | cut -d'/' -f1)
    [ -n "$AGG_PID" ] && kill "$AGG_PID" 2>/dev/null
    busybox fuser -k "$AGG_PORT/tcp" 2>/dev/null
    sleep 1
    
    local TUNNEL_LIST=""
    for i in $(busybox seq 0 $((WORKER_COUNT - 1))); do
        TUNNEL_LIST="$TUNNEL_LIST 127.0.0.1:$((BASE_WORKER_PORT + i))"
    done
    $BINDIR/libload -lport "$AGG_PORT" -tunnel $TUNNEL_LIST >> "$LOGFILE" 2>&1 &
    sleep 3
    
    if busybox nc -z 127.0.0.1 "$AGG_PORT" 2>/dev/null; then
        print_info "[AGG-MANAGER] Aggregator $AGG_PORT restarted successfully"
    else
        print_info "[AGG-MANAGER] WARNING: Aggregator $AGG_PORT restart may have failed"
    fi
    return 0
}

# -------------------------------------------------------------------
#  Restart ril-daemon (global recovery)
# -------------------------------------------------------------------
restart_rild() {
    print_info "[AGG-MANAGER] All aggregators failed. Restarting ril-daemon..."
    setprop ctl.restart ril-daemon 2>/dev/null || { stop ril-daemon; start ril-daemon; }
    sleep 60
    print_info "[AGG-MANAGER] ril-daemon restarted. Waiting for network..."
}

# -------------------------------------------------------------------
#  Aggregator Manager - monitors all aggregators (pure sh)
# -------------------------------------------------------------------
start_aggregator_manager() {
    (
        CHECK_INTERVAL=30
        FAIL_THRESHOLD=3
        
        # Read all aggregator ports from mapping file
        AGG_PORTS=""
        while IFS='|' read -r port config; do
            AGG_PORTS="$AGG_PORTS $port"
            # Reset fail counts on start
            reset_fail_count "$port"
        done < "$AGGREGATOR_MAP"
        
        if [ -z "$AGG_PORTS" ]; then
            print_info "[AGG-MANAGER] No aggregators to monitor. Exiting."
            exit 1
        fi
        
        print_info "[AGG-MANAGER] Started monitoring aggregators: $AGG_PORTS (interval ${CHECK_INTERVAL}s, threshold $FAIL_THRESHOLD)"
        
        while true; do
            sleep "$CHECK_INTERVAL"
            
            # Stop if main process died
            if [ ! -f "$PIDFILE" ] || ! pidof clash >/dev/null; then
                print_info "[AGG-MANAGER] QTUN core not running. Exiting."
                exit 0
            fi
            
            ANY_ALIVE=0
            ANY_FAILED=0
            
            for port in $AGG_PORTS; do
                # Test aggregator via socks5
                if $CURL -so /dev/null -x socks5h://127.0.0.1:"$port" --connect-timeout 5 --max-time 10 http://www.google.com 2>/dev/null; then
                    # Success
                    COUNT=$(get_fail_count "$port")
                    if [ "$COUNT" -ge "$FAIL_THRESHOLD" ]; then
                        print_info "[AGG-MANAGER] Aggregator $port recovered."
                    fi
                    reset_fail_count "$port"
                    ANY_ALIVE=1
                else
                    COUNT=$(get_fail_count "$port")
                    COUNT=$((COUNT + 1))
                    set_fail_count "$port" "$COUNT"
                    print_info "[AGG-MANAGER] Aggregator $port FAILED ($COUNT/$FAIL_THRESHOLD)"
                    if [ "$COUNT" -ge "$FAIL_THRESHOLD" ]; then
                        ANY_FAILED=1
                        restart_aggregator_workers "$port" "failed $COUNT times"
                        reset_fail_count "$port"
                        sleep 15  # give time to stabilize
                    fi
                fi
            done
            
            # If no aggregator alive after handling individual failures, restart ril-daemon
            if [ "$ANY_ALIVE" -eq 0 ] && [ "$ANY_FAILED" -eq 1 ]; then
                print_info "[AGG-MANAGER] All aggregators dead. Triggering global network recovery."
                restart_rild
                # Reset all fail counts after ril restart
                for port in $AGG_PORTS; do
                    reset_fail_count "$port"
                done
                sleep 30
            fi
        done
    ) &
    local pid=$!
    echo "$pid" > "$MANAGER_PIDFILE"
    log_msg "Aggregator Manager started PID=$pid"
}

# -------------------------------------------------------------------
#  Worker monitor (only for "no recent network activity")
# -------------------------------------------------------------------
start_worker_monitor() {
    (
        CHECK_INTERVAL=15
        WORKER_RESTART_THRESHOLD=5
        fail_count=0
        
        print_info "[WORKER-MONITOR] Started (only for 'no recent network activity')"
        while true; do
            sleep "$CHECK_INTERVAL"
            if [ ! -f "$PIDFILE" ] || ! pidof clash >/dev/null; then
                exit 0
            fi
            if [ -f "$LOGFILE" ]; then
                recent_activity=$(tail -n 100 "$LOGFILE" | grep -c "no recent network activity" 2>/dev/null)
                if [ "$recent_activity" -gt 0 ]; then
                    fail_count=$((fail_count + recent_activity))
                    print_info "[WORKER-MONITOR] 'no recent network activity' count: $fail_count/$WORKER_RESTART_THRESHOLD"
                    if [ "$fail_count" -ge "$WORKER_RESTART_THRESHOLD" ]; then
                        print_info "[WORKER-MONITOR] Restarting all workers due to persistent 'no recent activity'"
                        killall libuz 2>/dev/null
                        sleep 2
                        # Restart all workers from all configs
                        while IFS='|' read -r agg_port config_file; do
                            idx=$((agg_port - 7777))
                            base_port=$((1080 + idx * 1000))
                            wcount=$($JQ -r '.worker_count' "$config_file" 2>/dev/null)
                            [ -z "$wcount" ] || [ "$wcount" = "null" ] || [ "$wcount" -lt 1 ] && wcount=4
                            obfs=$($JQ -r '.obfs' "$config_file" 2>/dev/null)
                            for i in $(busybox seq 0 $((wcount - 1))); do
                                port=$((base_port + i))
                                json=$($JQ --arg port "$port" '.socks5.listen = "127.0.0.1:\($port)"' "$config_file")
                                $BINDIR/libuz -s "$obfs" --config "$json" >> "$LOGFILE" 2>&1 &
                                sleep 0.2
                            done
                        done < "$AGGREGATOR_MAP"
                        sleep 5
                        fail_count=0
                    fi
                else
                    if [ "$fail_count" -gt 0 ]; then
                        fail_count=$((fail_count - 1))
                    fi
                fi
            fi
        done
    ) &
    local pid=$!
    echo "$pid" > "$WORKER_MONITOR_PIDFILE"
    log_msg "Worker Monitor started PID=$pid"
}

# -------------------------------------------------------------------
#  Process a single config (start workers + aggregator)
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
    
    # Add to server IP list for Clash bypass
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
    
    sleep 2
    if ! pidof libuz >/dev/null; then
        print_info "  Workers FAILED"
        return 1
    fi
    print_info "  Workers started [OK]"
    
    # Start aggregator
    print_info "  Starting aggregator on port $AGG_PORT..."
    $BINDIR/libload -lport "$AGG_PORT" -tunnel $TUNNEL_LIST >> "$LOGFILE" 2>&1 &
    sleep 2
    if pidof libload >/dev/null; then
        print_info "  Aggregator on $AGG_PORT started [OK]"
        # Store mapping
        echo "$AGG_PORT|$CONFIG_FILE" >> "$AGGREGATOR_MAP"
        echo "$PROXY_NAME|$AGG_PORT" >> "$RUNDIR/aggregators.list"
    else
        print_info "  Aggregator FAILED"
        return 1
    fi
    return 0
}

# -------------------------------------------------------------------
#  Generate Clash config from aggregators
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
#  Main start logic
# -------------------------------------------------------------------
start() {
    echo "--- QTUN START: $(date) ---" > "$LOGFILE"
    log_msg "Starting QTUN Multi-Config v$VERSION with Aggregator Manager"
    
    for bin in libuz libload clash curl yq jq; do
        [ ! -f "$BINDIR/$bin" ] && cleanup_fail "Binary $BINDIR/$bin missing"
        chmod +x "$BINDIR/$bin" 2>/dev/null
    done
    
    killall libuz libload clash 2>/dev/null
    sleep 0.5
    show_banner
    
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
    sleep 3
    if ! pidof clash >/dev/null; then
        cleanup_fail "Clash failed to start"
    fi
    print_info "Clash started (PID $(cat $PIDFILE)) [OK]"
    
    print_info "Verifying aggregators..."
    while IFS='|' read -r name port; do
        if $CURL -so /dev/null -x socks5h://127.0.0.1:"$port" --connect-timeout 3 http://www.google.com 2>/dev/null; then
            print_info "  $name -> socks5://127.0.0.1:$port [OK]"
        else
            print_info "  $name -> socks5://127.0.0.1:$port [WARN] Not responding yet"
        fi
    done < "$RUNDIR/aggregators.list"
    
    echo ""
    echo "=========================================="
    echo "   QTUN Multi-Config is ONLINE"
    echo "   Aggregator Manager Active"
    echo "=========================================="
    echo " Clash Mixed Port: 127.0.0.1:7890"
    echo " Selector: AUTO"
    log_msg "[SUCCESS] System online with $(wc -l < "$RUNDIR/aggregators.list") aggregators."
    
    start_aggregator_manager
    start_worker_monitor
    start_log_rotator
}

# -------------------------------------------------------------------
#  Stop
# -------------------------------------------------------------------
stop() {
    print_info "Stopping QTUN services..."
    for pidf in "$MANAGER_PIDFILE" "$WORKER_MONITOR_PIDFILE" "$ROTATE_PIDFILE"; do
        [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null && rm -f "$pidf"
    done
    killall libuz libload clash 2>/dev/null
    rm -f "$PIDFILE"
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
    [ -f "$WORKER_MONITOR_PIDFILE" ] && echo " Worker Monitor PID: $(cat $WORKER_MONITOR_PIDFILE)" || echo " Worker Monitor    : Not running"
    [ -f "$ROTATE_PIDFILE" ] && echo " Log Rotator PID   : $(cat $ROTATE_PIDFILE)" || echo " Log Rotator       : Not running"
    echo " Log file          : $LOGFILE (rotated)"
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
    restart) stop; sleep 2; start ;;
    status)  status ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac