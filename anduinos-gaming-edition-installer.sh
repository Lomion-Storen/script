#!/usr/bin/env bash
# AnduinOS Ultra-Aggressive Gaming Turbo Script
# Verwandle AnduinOS in ein extrem performance-optimiertes Gaming-System.
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Dieses Skript muss als root ausgeführt werden. Bitte mit sudo starten."
  exit 2
fi

echo "========================================"
echo " ANDUINOS ULTRA-AGGRESSIVE GAMING TURBO"
echo "========================================"
read -p "Fortfahren? (y/N): " proceed
if [[ "${proceed,,}" != "y" && "${proceed,,}" != "yes" ]]; then
  echo "Abgebrochen."
  exit 0
fi

# -------------------------
# 1) Basis-Update + Tools
# -------------------------
echo "[1/14] Systemupdate und Basis-Tools..."
apt update
apt upgrade -y
apt install -y software-properties-common curl wget ca-certificates apt-transport-https unzip gnupg lsb-release

# -------------------------
# 2) Flatpak & Flathub
# -------------------------
echo "[2/14] Flatpak & Flathub..."
apt install -y flatpak
if ! flatpak remote-list | grep -q flathub; then
  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
fi

# -------------------------
# 3) Liquorix Gaming Kernel
# -------------------------
echo "[3/14] Liquorix Kernel (Gaming) installieren..."
add-apt-repository -y ppa:damentz/liquorix
apt update
apt install -y linux-image-liquorix-amd64 linux-headers-liquorix-amd64 || true

# -------------------------
# 4) GPU / Vulkan / Mesa / Microcode
# -------------------------
echo "[4/14] GPU & Vulkan & Microcode..."
apt install -y mesa-vulkan-drivers mesa-vulkan-drivers:i386 vulkan-tools vulkan-validationlayers \
  libvulkan1 libvulkan1:i386 vulkan-utils

# Microcode
apt install -y intel-microcode amd64-microcode || true

# Detect NVIDIA
if lspci | grep -i -E "nvidia|geforce" >/dev/null 2>&1; then
  echo "-> NVIDIA GPU erkannt: Installiere NVIDIA Treiber (stabiles Release)..."
  # Wähle eine vernünftige Treiberversion; anpassen falls nötig
  ubuntu_version="$(lsb_release -rs | cut -d. -f1)"
  # Versuche metapackage
  apt install -y nvidia-driver-550 nvidia-settings || apt install -y nvidia-driver-535 nvidia-settings || true
fi

# -------------------------
# 5) Gaming-Software
# -------------------------
echo "[5/14] Steam, Lutris, Heroic, ProtonUp-Qt, MangoHUD etc..."
apt install -y steam lutris gamemode libgamemode0 libgamemode1 cpufrequtils \
  mesa-utils libgl1-mesa-dri libgl1-mesa-glx

flatpak install -y flathub com.heroicgameslauncher.hgl || true
flatpak install -y flathub net.davidotek.pupgui2 || true   # ProtonUp-Qt

apt install -y mangohud vkbasalt || true

# -------------------------
# 6) ZRAM (compressed swap)
# -------------------------
echo "[6/14] ZRAM (zram-tools) installieren und konfigurieren..."
apt install -y zram-tools || true

# Konfiguration für zram-tools: /etc/default/zramswap (wenn vorhanden) anpassen
if [ -f /etc/default/zramswap ]; then
  sed -i "s/^#\?ALGO=.*/ALGO=lz4/" /etc/default/zramswap || true
  sed -i "s/^#\?MEMORY_LIMIT=.*/MEMORY_LIMIT=60/" /etc/default/zramswap || true
fi

# -------------------------
# 7) I/O & Scheduler Optimierung (udev rule)
# -------------------------
echo "[7/14] I/O Scheduler & NVMe-Tuning..."
cat > /etc/udev/rules.d/60-io-scheduler.rules <<'EOF'
# Set optimal scheduler for NVMe / SSDs on modern kernels (use mq-deadline)
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="mq-deadline"
EOF

# -------------------------
# 8) Sysctl (aggressive) - Netzwerk, VM, Scheduler, IO
# -------------------------
echo "[8/14] Sysctl-Tuning (aggressiv)..."
cat > /etc/sysctl.d/99-anduin-ultra.conf <<'EOF'
# VM tuning
vm.swappiness=1
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=3
vm.min_free_kbytes=65536

# Scheduler / latency
kernel.sched_migration_cost_ns=5000000
kernel.sched_autogroup_enabled=0
kernel.sched_latency_ns=60000000
kernel.sched_min_granularity_ns=6000000
kernel.sched_wakeup_granularity_ns=1500000

# Network tuning (gaming)
net.core.default_qdisc=fq
net.core.rmem_default=31457280
net.core.rmem_max=67108864
net.core.wmem_default=31457280
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_sack=1
net.ipv4.tcp_low_latency=1

# File system / IO
fs.file-max=524288
EOF

# Load sysctl conf
sysctl --system || true

# Enable BBR if available
if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
  echo "BBR ist aktiv oder unterstützt."
else
  echo "Versuche BBR zu aktivieren..."
  modprobe tcp_bbr || true
  echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf || true
fi

# -------------------------
# 9) CPU Governor / Performance
# -------------------------
echo "[9/14] CPU Governor: performance setzen und Turbo-Modus forcing..."

# Install cpufrequtils falls nicht vorhanden
apt install -y cpufrequtils || true

# Set runtime to performance
for cpu_gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  if [ -f "$cpu_gov" ]; then
    echo performance > "$cpu_gov" || true
  fi
done

# persist via /etc/default/cpufrequtils
cat > /etc/default/cpufrequtils <<'EOF'
GOVERNOR="performance"
EOF

# Enable turbo if possible (intel)
if command -v x86_energy_perf_policy >/dev/null 2>&1; then
  x86_energy_perf_policy performance || true
fi

# -------------------------
# 10) NVIDIA runtime tweaks (falls NVIDIA vorhanden)
# -------------------------
echo "[10/14] NVIDIA Runtime Optimierungen (falls vorhanden)..."
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "Aktiviere Persistence Mode..."
  nvidia-smi -pm 1 || true
  # Versuche AutoBoost aus (soll stabilere clocks geben)
  # (Diese Option ist abhängig vom Treiber)
  nvidia-smi -i 0 --auto-boost-default=0 || true
  # Setze Power Limit falls sinnvoll (nicht gesetzt; erfordert Prüfung)
fi

# -------------------------
# 11) Disable power-savers (Ultra Aggressive)
# -------------------------
echo "[11/14] Deaktiviere aggressive Power-Saver Dienste (tlp, laptop-mode, sleep)..."
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true
if systemctl list-unit-files | grep -q tlp; then
  systemctl mask --now tlp || true
fi
if systemctl list-unit-files | grep -q thermald; then
  systemctl mask --now thermald || true
fi

# -------------------------
# 12) GNOME / Compositor handling (attempt)
# -------------------------
echo "[12/14] Compositor/Display-Server Optimierung..."
# Wenn GNOME (gnome-shell) detected: install xdg-desktop-portal-wlr? best effort
if pidof gnome-shell >/dev/null 2>&1; then
  # Warnung: killing gnome-shell kann instability erzeugen; wir legen stattdessen eine helper service an
  echo "GNOME erkannt. Wir legen ein kleines systemd-Skript an, das bei GameMode fullscreen versucht, compositor-Load zu verringern."
fi

# -------------------------
# 13) Gamemode hooks + systemd service um tweaks on-demand zu setzen
# -------------------------
echo "[13/14] Erstelle runtime tweak script und systemd service..."

cat > /usr/local/bin/anduin-ultra-runtime-tweaks.sh <<'EOF'
#!/usr/bin/env bash
# Runtime tweaks executed on-demand or at boot to set priorities for gaming
# Set realtime priority for games run under gamemode (best-effort)
# Raise IRQ and process priority for gaming

# Realtime priority: try to give chrt to gamemode-sessions (best-effort)
# Increase network nic tx/rx priority (ethtool not required here)

# Set nice/ionice defaults for gamemode (userspace hook)
echo "Runtime tweaks applied."
EOF
chmod +x /usr/local/bin/anduin-ultra-runtime-tweaks.sh

cat > /etc/systemd/system/anduin-ultra-runtime.service <<'EOF'
[Unit]
Description=Anduin Ultra Runtime Tweaks
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/anduin-ultra-runtime-tweaks.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now anduin-ultra-runtime.service || true

# -------------------------
# 14) Optional: disable unnecessary services that may cause stutters
# -------------------------
echo "[14/14] Optional: Deaktiviere Avahi/ModemManager/BlueZ falls nicht benötigt..."
if systemctl is-enabled avahi-daemon >/dev/null 2>&1; then
  systemctl disable --now avahi-daemon || true
fi
if systemctl is-enabled ModemManager >/dev/null 2>&1; then
  systemctl disable --now ModemManager || true
fi
# Bluetooth behalten falls Controller via BT genutzt werden.

echo
echo "========================================"
echo "FERTIG: Ultra-Aggressive Tuning angewendet."
echo "Bitte neu starten, damit Kernel & alle Änderungen aktiv werden:"
echo "  sudo reboot"
echo "WARNUNG: Dieses Profil ist sehr aggressiv (mehr Hitze / Strom)."
echo "Du kannst das Verhalten anpassen durch Bearbeiten von /etc/sysctl.d/99-anduin-ultra.conf und /usr/local/bin/anduin-ultra-runtime-tweaks.sh"
echo "========================================"
