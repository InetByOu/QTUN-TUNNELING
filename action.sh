#!/system/bin/sh
#=============================================
# QTUN Action Toggle
# Author      : azyanggara
# Contributor : E-Mod
#=============================================

export PATH=/sbin:/system/bin:/system/xbin:/data/adb/magisk:/data/adb/bin:$PATH

mkdir -p /data/adb/QTUN/run
RUNLOG="/data/adb/QTUN/run/run.log"

stop_service() {
    echo "[-] QTUN: Stopping Services..."
    echo "[$(date '+%H:%M:%S')] [ACTION] Stop Request" >> "$RUNLOG"
    
    /data/adb/QTUN/scripts/qtun.iptables disable >> "$RUNLOG" 2>&1
    /data/adb/QTUN/scripts/qtun.service stop >> "$RUNLOG" 2>&1
    
    rm -f /data/adb/QTUN/run/qtun.pid
    touch /data/adb/modules/qtun_tunneling/disable
    echo "[OK] Status: OFFLINE"
}

start_service() {
    echo "[+] QTUN: Starting Services..."
    echo "[$(date '+%H:%M:%S')] [ACTION] Start Request" >> "$RUNLOG"
    
    rm -f /data/adb/modules/qtun_tunneling/disable
    
    if /data/adb/QTUN/scripts/qtun.service start >> "$RUNLOG" 2>&1; then
        /data/adb/QTUN/scripts/qtun.iptables enable >> "$RUNLOG" 2>&1
        echo "[$(date '+%H:%M:%S')] [ACTION] System Ready." >> "$RUNLOG"
        echo "[OK] Status: ONLINE"
    else
        echo "[!] FAILED: Check $RUNLOG"
        exit 1
    fi
}

# Logika toggle
if [ -f "/data/adb/QTUN/run/qtun.pid" ]; then
    PID=$(cat "/data/adb/QTUN/run/qtun.pid")
    if [ -d "/proc/$PID" ]; then
        stop_service
    else
        rm -f "/data/adb/QTUN/run/qtun.pid"
        start_service
    fi
else
    if pgrep -x "clash" > /dev/null; then
        stop_service
    else
        start_service
    fi
fi