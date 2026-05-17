#!/system/bin/sh
# QTUN Boot Handler
scripts_dir="/data/adb/QTUN/scripts"
run_dir="/data/adb/QTUN/run"
moddir="/data/adb/modules/qtun_tunneling"

[ -f "$moddir/disable" ] && exit 0
[ -f "/data/adb/QTUN/manual" ] && exit 1

mkdir -p "$run_dir"
echo "=== QTUN BOOT SESSION: $(date) ===" > "$run_dir/run.log"

"$scripts_dir/qtun.service" stop >> "$run_dir/run.log" 2>&1
"$scripts_dir/qtun.iptables" disable >> "$run_dir/run.log" 2>&1

if "$scripts_dir/qtun.service" start >> "$run_dir/run.log" 2>&1; then
    "$scripts_dir/qtun.iptables" enable >> "$run_dir/run.log" 2>&1
    echo "[$(date '+%H:%M:%S')] [BOOT] System Ready." >> "$run_dir/run.log"
else
    echo "[$(date '+%H:%M:%S')] [BOOT] FAILED to start core." >> "$run_dir/run.log"
    exit 1
fi