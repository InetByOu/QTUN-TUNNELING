# QTUN TUNNELING Mod

**Modul Magisk/KernelSU
VPN Tunneling dengan ZIVPN Core + Clash**

QTUN TUNNELING adalah modul root Android yang menggabungkan custom core ZIVPN (protokol Hysteria) dengan Clash Meta untuk menghasilkan koneksi cepat, stabil, dan mudah dikonfigurasi.

## 🆕 Apa Fitur barunya?

- 🎛️ **Konfigurasi Terpusat**
- Semua pengaturan (server, obfs, auth, jumlah worker) kini ada di  
  `config/user_config.json`. Tidak perlu lagi edit banyak file.
- 👷 **Jumlah Worker Manual**
- Jumlah worker (`worker_count`) diambil dari config, bukan lagi dari jumlah core CPU.
- 🧠 **Deteksi Arsitektur Otomatis**
- Modul langsung memilih binary ARM atau ARM64 sesuai perangkat, tanpa pilih-pilih folder.
- 📡 **Manajer Koneksi Internet**
- Memonitor koneksi lewat aggregator. Jika internet mati, jaringan direstart otomatis agar koneksi kembali normal.
- 🔒 **Firewall Lebih Pintar**
- `qtun.iptables` sekarang juga mengikuti arsitektur untuk binary `jq`.
- 🐞 Perbaikan bug dan peningkatan stabilitas.

## Fitur Utama

- **ZIVPN Core Multi‑Worker**
Memanfaatkan `libuz` worker paralel yang diaggregasi oleh `libload`.
- **Clash Meta**
TUN mode, DNS hijack, proxy HTTP/SOCKS5, dan dashboard (opsional).
- **Auto‑Deteksi ARM/ARM64**
Satu file zip, bisa langsung flash tanpa mikir.
- **Konfigurasi Simpel**
Cukup edit satu file JSON, atur server, password, jumlah worker, dll.
- **Self‑Healing**
Pantau internet terus‑menerus; jika putus restart internet tanpa membuat hotspot mati.
- **Toggle ON/OFF**
Bisa diaktifkan/dimatikan dari Magisk Manager.

## Cara Install

1. Unduh **QTUN‑TUNNELING.zip** dari release.
2. Flash melalui Magisk atau KernelSU.
3. Reboot perangkat.
4. Edit `/data/adb/QTUN/config/user_config.json` sesuai akun ZIVPN lo.
5. Aktifkan modul (bisa lewat toggle atau reboot sekali lagi).

> Pastikan lo sudah punya server ZIVPN yang aktif.
## SpeedTest
<img width="720" height="1612" alt="Screenshot_20260512-180355" src="https://github.com/user-attachments/assets/a8c077a5-9900-4b08-b1e4-207b5a4c9a28" />

## Kredit

- **Pembuat:** [azyanggara](https://github.com/azyanggara)  
- **Kontributor:** E‑Mod  
- **Kode Dasar:**  
  - [QcomWrt/QTUN-TUNNELING](https://github.com/QcomWrt/QTUN-TUNNELING) (ori)  
  - [InetByOu/QTUN-TUNNELING](https://github.com/InetByOu/QTUN-TUNNELING/releases) (pembaruan)

Selamat mencoba! Kalau ada kendala, silakan buka issue atau diskusi.
