#!/system/bin/sh
#=============================================
# QTUN Uninstall Script
# Author      : azyanggara
# Contributor : E-Mod
#=============================================

QTUN_DIR="/data/adb/QTUN"

echo "------------------------------------------"
echo "         QTUN UNINSTALLER"
echo "------------------------------------------"

# 1. Hentikan semua proses
echo "[$(date '+%H:%M:%S')] Stopping all processes..."
killall libuz libload clash 2>/dev/null
echo "[$(date '+%H:%M:%S')] Processes stopped [OK]"

# 2. Matikan iptables agar internet tidak putus
if [ -f "$QTUN_DIR/scripts/qtun.iptables" ]; then
    echo "[$(date '+%H:%M:%S')] Flushing iptables rules..."
    sh "$QTUN_DIR/scripts/qtun.iptables" disable >/dev/null 2>&1
    echo "[$(date '+%H:%M:%S')] Iptables flushed [OK]"
fi

# 3. Hapus folder utama QTUN
if [ -d "$QTUN_DIR" ]; then
    rm -rf "$QTUN_DIR"
    echo "[$(date '+%H:%M:%S')] QTUN directory removed [OK]"
fi

# 4. Hapus backup config di sdcard
rm -f /sdcard/qtun_config_bak.json

echo "------------------------------------------"
echo "   QTUN Uninstalled Successfully."
echo "   Thank you for using QTUN."
echo "------------------------------------------"