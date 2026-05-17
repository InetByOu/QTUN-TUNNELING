#!/system/bin/sh
#=============================================
# QTUN Boot Service
# Author      : azyanggara
# Contributor : E-Mod
#=============================================

(
    # Tunggu boot animation selesai
    until [ "$(getprop init.svc.bootanim)" = "stopped" ]; do
        sleep 10
    done

    sleep 10

    if [ -f "/data/adb/QTUN/scripts/start.sh" ]; then
        chmod -R 755 /data/adb/QTUN/scripts/
        /data/adb/QTUN/scripts/start.sh >/dev/null 2>&1
    else
        mkdir -p /data/adb/QTUN/run
        echo "[$(date '+%H:%M:%S')] [BOOT] Error: start.sh not found" > "/data/adb/QTUN/run/boot_err.log"
    fi
) &