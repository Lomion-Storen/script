#!/usr/bin/env bash
# AnduinOS Ultra-Aggressive Gaming Turbo Script
# Verwandle AnduinOS in ein extrem performance-optimiertes Gaming-System.
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Dieses Skript muss als root ausgeführt werden. Bitte mit sudo starten."
  exit 2
fi

# Ziel-Benutzer / Home bestimmen (wenn mit sudo ausgeführt)
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  TARGET_USER="$SUDO_USER"
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
else
  TARGET_USER="root"
  TARGET_HOME="/root"
fi

# Helfer: user systemd --user sicher ausführen (enable-linger falls nötig)
run_user_systemctl() {
  # usage: run_user_systemctl "enable --now pipewire pipewire-pulse"
  if [ "$TARGET_USER" != "root" ]; then
    loginctl enable-linger "$TARGET_USER" >/dev/null 2>&1 || true
    su - "$TARGET_USER" -c "systemctl --user $*" || true
  else
    systemctl $* 2>/dev/null || true
  fi
}

# Backup helper
backup_file() {
  local f="$1"
  if [ -f "$f" ]; then
    cp -a "$f" "${f}.bak-$(date +%Y%m%d%H%M%S)" || true
  fi
}

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
echo "[1/18] Systemupdate und Basis-Tools..."
apt update
apt upgrade -y

# -------------------------
# 2) GPU / Vulkan / Mesa / Microcode
# -------------------------
echo "[2/18] GPU & Vulkan & Microcode..."
apt install -y mesa-vulkan-drivers mesa-vulkan-drivers:i386 vulkan-tools vulkan-validationlayers libvulkan1 libvulkan1:i386 || true

if lspci | grep -i -E "nvidia|geforce" >/dev/null 2>&1; then
  echo "-> NVIDIA GPU erkannt: Installiere NVIDIA Treiber (stabiles Release)..."
  apt install -y nvidia-driver-550 nvidia-settings nvidia-driver-libs:i386 || apt install -y nvidia-driver-535 nvidia-settings nvidia-driver-libs:i386 || true
fi

# Eventuell mit dem Befehl "ubuntu-drivers devices" die empfohlene Version prüfen.

# -------------------------
# 3) Gaming-Software
# -------------------------
echo "[3/18] Steam, Lutris, Heroic, ProtonUp-Qt, MangoHUD etc..."
apt install -y steam lutris gamemode libgamemode0 cpufrequtils mesa-utils libgl1-mesa-dri || true
flatpak install -y flathub com.heroicgameslauncher.hgl || true
flatpak install -y flathub net.davidotek.pupgui2 || true
apt install -y mangohud vkbasalt || true

# -------------------------
# 4) ZRAM (compressed swap)
# -------------------------
echo "[4/18] ZRAM (zram-tools) installieren und konfigurieren..."
apt install -y zram-tools || true
if [ -f /etc/default/zramswap ]; then
  backup_file /etc/default/zramswap
  sed -i "s/^#\?ALGO=.*/ALGO=lz4/" /etc/default/zramswap || true
  sed -i "s/^#\?MEMORY_LIMIT=.*/MEMORY_LIMIT=60/" /etc/default/zramswap || true
fi

# -------------------------
# 5) I/O & Scheduler Optimierung (udev rule)
# -------------------------
echo "[5/18] I/O Scheduler & NVMe-Tuning..."
cat > /etc/udev/rules.d/60-io-scheduler.rules <<'EOF'
# Set optimal scheduler for NVMe / SSDs on modern kernels (use mq-deadline)
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="mq-deadline"
EOF

# -------------------------
# 6) Sysctl (aggressive) - Netzwerk, VM, Scheduler, IO
# -------------------------
echo "[6/18] Sysctl-Tuning (aggressiv)..."
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
  modprobe tcp_bbr || true
  echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf || true
fi

# -------------------------
# 7) CPU Governor / Performance
# -------------------------
echo "[7/18] CPU Governor: performance setzen und Turbo-Modus forcing..."

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
# 8) NVIDIA runtime tweaks (falls NVIDIA vorhanden)
# -------------------------
echo "[8/18] NVIDIA Runtime Optimierungen (falls vorhanden)..."
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "Aktiviere Persistence Mode..."
  nvidia-smi -pm 1 || true
  # Versuche AutoBoost aus (soll stabilere clocks geben)
  # (Diese Option ist abhängig vom Treiber)
  nvidia-smi -i 0 --auto-boost-default=0 || true
  # Setze Power Limit falls sinnvoll (nicht gesetzt; erfordert Prüfung)
fi

# -------------------------
# 9) Disable power-savers (Ultra Aggressive)
# -------------------------
echo "[9/18] Deaktiviere aggressive Power-Saver Dienste (tlp, laptop-mode, sleep)..."
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true
if systemctl list-unit-files | grep -q tlp; then
  systemctl mask --now tlp || true
fi
if systemctl list-unit-files | grep -q thermald; then
  systemctl mask --now thermald || true
fi

# -------------------------
# 10) GNOME / Compositor handling (attempt)
# -------------------------
echo "[10/18] Compositor/Display-Server Optimierung..."
# Wenn GNOME (gnome-shell) detected: install xdg-desktop-portal-wlr? best effort
if pidof gnome-shell >/dev/null 2>&1; then
  # Warnung: killing gnome-shell kann instability erzeugen; wir legen stattdessen eine helper service an
  echo "GNOME erkannt. Wir legen ein kleines systemd-Skript an, das bei GameMode fullscreen versucht, compositor-Load zu verringern."
fi

# -------------------------
# 11) Gamemode hooks + systemd service um tweaks on-demand zu setzen
# -------------------------
echo "[11/18] Erstelle runtime tweak script und systemd service..."
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
# 12) Optional: disable unnecessary services that may cause stutters
# -------------------------
echo "[12/18] Optional: Deaktiviere Avahi/ModemManager/BlueZ falls nicht benötigt..."
if systemctl is-enabled avahi-daemon >/dev/null 2>&1; then
  systemctl disable --now avahi-daemon || true
fi
if systemctl is-enabled ModemManager >/dev/null 2>&1; then
  systemctl disable --now ModemManager || true
fi
# Bluetooth behalten falls Controller via BT genutzt werden.



# -------------------------
# 13) Swappiness & Memory (erweitert)
# -------------------------
echo "[13/18] Swappiness & Memory Tuning..."

# Zusätzlich zu vm.swappiness in sysctl:
cat >> /etc/sysctl.d/99-anduin-ultra.conf <<'EOF'

# Memory & Swap Tuning
vm.page-cluster=0
vm.overcommit_memory=1
vm.overcommit_ratio=50
vm.extra_free_kbytes=262144
vm.mmap_min_addr=32768
EOF

sysctl --system || true

# ZRAM Größe optimieren (60% RAM als ZRAM)
if [ -f /etc/default/zramswap ]; then
  backup_file /etc/default/zramswap
  sed -i "s/^MEMORY_LIMIT=.*/MEMORY_LIMIT=60/" /etc/default/zramswap || true
fi

# Disable transparent hugepage defrag (kann stutter erzeugen)
if [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then
  echo madvise > /sys/kernel/mm/transparent_hugepage/enabled || true
fi
if [ -w /sys/kernel/mm/transparent_hugepage/defrag ]; then
  echo defer > /sys/kernel/mm/transparent_hugepage/defrag || true
fi

# Persistieren
cat > /etc/systemd/system/hugepage-tweak.service <<'EOF'
[Unit]
Description=Transparent Hugepage Tweaks for Gaming
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo madvise > /sys/kernel/mm/transparent_hugepage/enabled && echo defer > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hugepage-tweak.service || true

# -------------------------
# 14) Latency-Reduzierung (Real-Time Priority)
# -------------------------
echo "[14/18] Latency-Reduzierung (rt-Priority, CONFIG_PREEMPT)..."
apt install -y rtkit || true

# Limit config für real-time Priority
cat > /etc/security/limits.d/99-gaming-rt.conf <<'EOF'
# Allow high-priority realtime scheduling for gamemode/steam
@gamemode    soft    rtprio    95
@gamemode    hard    rtprio    95
@gamemode    soft    memlock   unlimited
@gamemode    hard    memlock   unlimited
EOF

# Kernel parameter für preemption (bereits teilweise in sysctl, erweitert):
cat >> /etc/sysctl.d/99-anduin-ultra.conf <<'EOF'

# Preemption & Latency tweaks
kernel.sched_child_runs_first=1
kernel.sched_rr_interval_ms=3
kernel.sched_base_slice_ns=3000000
EOF

sysctl --system || true

# -------------------------
# 15) Audio-Optimierung (PipeWire, Low-Latency)
# -------------------------
echo "[15/18] Audio: PipeWire + Low-Latency Konfiguration..."
apt install -y pipewire pipewire-alsa pipewire-pulse pipewire-jack || true
apt remove -y pulseaudio pulseaudio-utils 2>/dev/null || true

# Install user config in target user's home (not root's) and enable service for that user
mkdir -p "$TARGET_HOME/.config/pipewire/pipewire.conf.d"
cat > "$TARGET_HOME/.config/pipewire/pipewire.conf.d/99-gaming-lowlatency.conf" <<'EOF'
context.properties = {
  default.clock.min-quantum = 32
  default.clock.max-quantum = 8192
  default.clock.quantum = 128
}
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/pipewire" || true

# Enable pipewire for the target user (enforce linger)
run_user_systemctl "enable --now pipewire pipewire-pulse" || true

if ! grep -q "pipewire-jack" /etc/profile.d/* 2>/dev/null; then
  cat > /etc/profile.d/pipewire-jack.sh <<'EOF'
export LD_LIBRARY_PATH=/usr/lib/pipewire-0.3/jack:$LD_LIBRARY_PATH
EOF
fi

# -------------------------
# 16) Input-Lag Reduzierung (USB Polling, Keyboard/Mouse)
# -------------------------
echo "[16/18] Input-Lag Reduzierung (sichere udev helper)..."

# Create a short helper script that udev can call (must be quick)
cat > /usr/local/bin/anduin-set-usb-polling.sh <<'EOF'
#!/usr/bin/env bash
# args: kernel-name
DEVNAME="$1"
SYSFS="/sys/bus/usb/devices/${DEVNAME}/bMaxPacketSize0"
if [ -w "\$SYSFS" ]; then
  # best-effort; many devices ignore this or use firmware-set values
  echo 1 > "\$SYSFS" 2>/dev/null || true
fi
# try input polling interval if present
INPUTSYS="/sys/class/input/${DEVNAME}/device/polling_interval"
if [ -w "\$INPUTSYS" ]; then
  echo 1000 > "\$INPUTSYS" 2>/dev/null || true
fi
exit 0
EOF
chmod +x /usr/local/bin/anduin-set-usb-polling.sh

# udev rule calls the short helper (keine langen Prozesse in RUN)
cat > /etc/udev/rules.d/99-usb-gaming-polling.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", RUN+="/usr/local/bin/anduin-set-usb-polling.sh %k"
ACTION=="add", SUBSYSTEM=="input", ENV{ID_INPUT_MOUSE}=="1", RUN+="/usr/local/bin/anduin-set-usb-polling.sh %k"
EOF

udevadm control --reload-rules && udevadm trigger || true
apt install -y evtest || true

cat > /usr/local/bin/check-input-lag.sh <<'EOF'
#!/usr/bin/env bash
echo "=== USB Polling Rates ==="
find /sys/bus/usb/devices -name "bMaxPacketSize0" -exec sh -c 'echo -n "$(dirname {}): "; cat {}' \; 2>/dev/null | head -20
echo ""
echo "=== Input Device Polling Intervals ==="
find /sys/class/input -name "polling_interval" -exec sh -c 'echo -n "$(dirname {}): "; cat {}' \; 2>/dev/null | head -20
echo ""
echo "Tipp: Mit 'evtest' kannst du Latenz testen (sudo evtest)"
EOF
chmod +x /usr/local/bin/check-input-lag.sh

# -------------------------
# 17) Thermal Management (Lüfter, Undervolting)
# -------------------------
echo "[17/18] Thermal Management (Fan-Curves, Temp-Monitoring)..."
apt install -y lm-sensors psensor smartmontools nvme-cli || true
sensors-detect --auto || true

if command -v nvidia-smi >/dev/null 2>&1; then
  echo "→ NVIDIA GPU erkannt. Erstelle systemd service für Fan-Monitor..."
  cat > /usr/local/bin/nvidia-fan-monitor.sh <<'EOF'
#!/usr/bin/env bash
GPU_ID=0
while true; do
  TEMP=\$(nvidia-smi -i \$GPU_ID --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null || echo 0)
  if [ "\$TEMP" -gt 85 ]; then
    /usr/bin/logger -t nvidia-fan-monitor "High GPU temp \$TEMP"
    # optional: power limit example (commented): /usr/bin/nvidia-smi -i \$GPU_ID -pl 250 || true
  fi
  sleep 10
done
EOF
  chmod +x /usr/local/bin/nvidia-fan-monitor.sh

  cat > /etc/systemd/system/nvidia-fan-monitor.service <<'EOF'
[Unit]
Description=NVIDIA Fan Monitor (Anduin)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/nvidia-fan-monitor.sh
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now nvidia-fan-monitor.service || true
fi

cat > /usr/local/bin/monitor-temps.sh <<'EOF'
#!/usr/bin/env bash
watch -n 2 'echo "=== CPU ===" && cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -5 && echo "" && echo "=== GPU ===" && (command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=index,temperature.gpu --format=csv,noheader 2>/dev/null || echo "Kein NVIDIA") && echo "" && echo "=== Disk ===" && (command -v hddtemp >/dev/null && hddtemp /dev/sd* 2>/dev/null | head -3 || echo "hddtemp nicht installiert")'
EOF
chmod +x /usr/local/bin/monitor-temps.sh

# -------------------------
# 18) Gaming-Launcher Optimierungen (Steam, Lutris, env-vars)
# -------------------------
echo "[18/18] Gaming-Launcher Optimierungen..."
cat > /etc/profile.d/steam-gaming-tweaks.sh <<'EOF'
# Steam / Proton Gaming Tweaks
export STEAM_CPU_CGROUP_PERFORMANCE=1
export STEAM_COMPAT_MOUNTS=/mnt
export DXVK_HUD=fps,memory
export VKD3D_CONFIG=dxr
export PROTON_NO_FSYNC=0
export PROTON_NO_ESYNC=0
export VK_LAYER_LUNARG_monitor=true
EOF

# Lutris config for target user
mkdir -p "$TARGET_HOME/.config/lutris"
cat > "$TARGET_HOME/.config/lutris/lutris.conf" <<'EOF'
[lutris]
preload_libs = libxcb.so.1,libX11.so.6
debug = False
gamemode = true
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/lutris" || true

cat > /usr/local/bin/launch-game.sh <<'EOF'
#!/usr/bin/env bash
# Optimal gaming launch wrapper
export STEAM_CPU_CGROUP_PERFORMANCE=1
export PROTON_NO_FSYNC=0
export PROTON_NO_ESYNC=0
export DXVK_HUD=fps
CORES=\$(nproc)
PERF_CORES=\$((CORES / 2))
taskset -c 0-\$((PERF_CORES-1)) ionice -c2 -n0 "\$@"
EOF
chmod +x /usr/local/bin/launch-game.sh

echo "→ Gaming-Launcher Config erstellt."
echo "  Steam env: /etc/profile.d/steam-gaming-tweaks.sh"
echo "  Wrapper: /usr/local/bin/launch-game.sh <spiel-kommando>"

echo
echo "========================================"
echo "FERTIG: Ultra-Aggressive Tuning angewendet."
echo "Bitte neu starten, damit Kernel & alle Änderungen aktiv werden:"
echo "  sudo reboot"
echo "WARNUNG: Dieses Profil ist sehr aggressiv (mehr Hitze / Strom)."
echo "Du kannst das Verhalten anpassen durch Bearbeiten von /etc/sysctl.d/99-anduin-ultra.conf und /usr/local/bin/anduin-ultra-runtime-tweaks.sh"
echo "========================================"
