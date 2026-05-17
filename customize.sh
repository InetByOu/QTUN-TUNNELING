#!/system/bin/sh
#=============================================
# QTUN Module Installer
# Author      : azyanggara
# Contributor : E-Mod
#=============================================

SKIPUNZIP=1
QTUN_DIR="/data/adb/QTUN"

# --- Banner Instalasi ---
ui_print "=========================================="
ui_print "       QTUN TUNNELING PROJECT"
ui_print "=========================================="
ui_print " Author     : azyanggara"
ui_print " Version    : $(grep_prop version $MODPATH/module.prop)"
ui_print " Build Date : $(grep_prop buildDate $MODPATH/module.prop)"
ui_print " Platform   : $([ "$KSU" = true ] && echo "KernelSU" || echo "Magisk")"
ui_print "------------------------------------------"

# --- Validasi Bootmode ---
if [ "$BOOTMODE" != true ]; then
  ui_print " Install via Magisk/KernelSU Manager only"
  abort "=========================================="
fi

# --- Ekstraksi ---
ui_print " Extracting module files..."
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2

# --- Deploy folder QTUN ---
if [ -d "$MODPATH/QTUN" ]; then
  ui_print " Deploying core to $QTUN_DIR"

  # Backup konfigurasi lama (jika ada)
  if [ -f "$QTUN_DIR/libuz/config.json" ]; then
    ui_print " Backing up old config..."
    cp "$QTUN_DIR/libuz/config.json" /sdcard/qtun_config_bak.json
  fi

  # Hapus folder lama dan ganti baru
  rm -rf "$QTUN_DIR"
  mv "$MODPATH/QTUN" /data/adb/

  # Restore backup config
  if [ -f /sdcard/qtun_config_bak.json ]; then
    mv /sdcard/qtun_config_bak.json "$QTUN_DIR/libuz/config.json"
    rm -f /sdcard/qtun_config_bak.json
    ui_print " Old config restored [OK]"
  fi
fi

# --- Permissions ---
ui_print " Setting permissions..."

set_perm_recursive "$QTUN_DIR" 0 3004 0755 0644
chmod -R +x "$QTUN_DIR/bin/"
chmod -R +x "$QTUN_DIR/scripts/"

set_perm_recursive "$MODPATH" 0 0 0755 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm /data/adb/modules/qtun_tunneling/action.sh 0 0 0755

ui_print "------------------------------------------"
ui_print "    INSTALLATION DONE. REBOOT DEVICE."
ui_print "=========================================="