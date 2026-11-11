#!/usr/bin/env bash
# Met à jour Scaros à la main, sans passer par internet pour Scaros lui-même : installe la version
# contenue dans le dossier de ce script, puis relance l'écran. Cette version ne se met pas à jour toute seule.
#   1. mets le dossier de la nouvelle version sur le PC (clé USB, ou zip téléchargé puis décompressé)
#   2. su -   puis   bash /chemin/vers/scaros-os/update.sh
set -euo pipefail

STATUS_DIR=/var/lib/scaros
[ "$(id -u)" -eq 0 ] || { echo "Lance la mise à jour en root : tape « su - » puis « bash $0 »."; exit 1; }
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$src/launcher/scaros.py" ] || [ ! -d "$src/system" ]; then
  echo "Lance ce script depuis le dossier de la nouvelle version de Scaros (celui qui contient launcher/ et system/)."
  exit 1
fi

# étape en cours, lue par le menu (install, done, failed) : après le redémarrage de l'écran, il affiche
# « Scaros est à jour »
status() {
  mkdir -p "$STATUS_DIR"
  printf '{"step": "%s", "at": %s}\n' "$1" "$(date +%s)" > "$STATUS_DIR/update-status.json.tmp"
  chmod 644 "$STATUS_DIR/update-status.json.tmp"
  mv -f "$STATUS_DIR/update-status.json.tmp" "$STATUS_DIR/update-status.json"
}
on_exit() {
  local rc=$?
  [ "$rc" -eq 0 ] || status "failed"
}
trap on_exit EXIT
echo "Installation de Scaros depuis $src…"
status "install"

# 2) paquets ajoutés depuis l'installation
NEW_PACKAGES=(
  libspa-0.2-bluetooth
  # AirPlay : recopie d'écran depuis un iPhone (UxPlay et le décodage vidéo GStreamer)
  uxplay avahi-daemon avahi-utils gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav
  gstreamer1.0-x gstreamer1.0-gl gstreamer1.0-pulseaudio
  # volume et notifications affichés par-dessus les applis
  python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-rsvg-2.0 fontconfig
  # diagnostic réseau (Réglages › Wi-Fi › Diagnostic réseau)
  tcpdump iputils-arping iw
  # musique en cours sur l'écran de veille (Spotify Connect, via MPRIS)
  playerctl libpulse0 libdbus-1-3
)
missing=()
for pkg in "${NEW_PACKAGES[@]}"; do
  dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Installation de : ${missing[*]}…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends "${missing[@]}"
  [[ " ${missing[*]} " == *" libspa-0.2-bluetooth "* ]] && need_reboot=1
fi

# cette version ne se met à jour qu'à la main : on retire la mise à jour par GitHub d'une installation d'avant
systemctl disable --now scaros-update.service >/dev/null 2>&1 || true
rm -f /usr/local/bin/scaros-update /etc/systemd/system/scaros-update.service /etc/scaros/source.conf /opt/scaros/commit
rmdir /etc/scaros 2>/dev/null || true

# AirPlay : l'iPhone trouve Scaros grâce à Avahi (Bonjour). Il doit tourner et publier les
# services (une option « disable-publishing » ou IPv4 coupé le rendrait invisible)
avahi_conf=/etc/avahi/avahi-daemon.conf
if [ -f "$avahi_conf" ]; then
  sed -E 's/^[[:space:]]*disable-publishing[[:space:]]*=[[:space:]]*yes/disable-publishing=no/;
          s/^[[:space:]]*use-ipv4[[:space:]]*=[[:space:]]*no/use-ipv4=yes/' "$avahi_conf" > "$avahi_conf.scaros"
  if cmp -s "$avahi_conf" "$avahi_conf.scaros"; then rm -f "$avahi_conf.scaros"
  else mv -f "$avahi_conf.scaros" "$avahi_conf"; systemctl restart avahi-daemon >/dev/null 2>&1 || true; fi
fi
systemctl enable --now avahi-daemon >/dev/null 2>&1 || true

# sans économie d'énergie Wi-Fi, le portable reste joignable (télécommande, AirPlay, SSH) :
# sinon la carte s'assoupit et le téléphone ne le trouve plus au bout d'un moment
mkdir -p /etc/NetworkManager/conf.d
printf '[connection]\nwifi.powersave = 2\n' > /etc/NetworkManager/conf.d/scaros-wifi.conf
for dev in /sys/class/net/wl*; do
  [ -e "$dev" ] && iw dev "$(basename "$dev")" set power_save off 2>/dev/null || true
done
wifi_modprobe="# Scaros : la carte Wi-Fi ne s'assoupit jamais (cartes Realtek et Intel)
options rtw88_core disable_lps_deep=y
options rtw89_core disable_ps_mode=y
options iwlmvm power_scheme=1"
# réglage des pilotes : pris en compte au prochain démarrage (redémarrage si la carte est concernée)
if [ "$(cat /etc/modprobe.d/scaros-wifi.conf 2>/dev/null)" != "$wifi_modprobe" ]; then
  printf '%s\n' "$wifi_modprobe" > /etc/modprobe.d/scaros-wifi.conf
  if grep -qE '^(rtw88_core|rtw89_core|iwlmvm) ' /proc/modules; then need_reboot=1; fi
fi

# mode souris (télécommande et manette) : une souris virtuelle (uinput) que le compte de la box
# a le droit de créer, sans accélération ajoutée par Xorg (la télécommande et la manette la calculent)
echo uinput > /etc/modules-load.d/scaros-uinput.conf
cat > /etc/udev/rules.d/60-scaros-uinput.rules <<'EOF'
KERNEL=="uinput", SUBSYSTEM=="misc", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
EOF
modprobe uinput 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true
if [ -e /dev/uinput ]; then chgrp input /dev/uinput 2>/dev/null && chmod 660 /dev/uinput 2>/dev/null || true; fi
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/40-scaros-souris.conf <<'EOF'
# Scaros OS : souris virtuelle du mode souris, sans accélération (calculée par la télécommande)
Section "InputClass"
    Identifier "Scaros souris"
    MatchProduct "Scaros souris"
    Option "AccelProfile" "flat"
    Option "AccelSpeed" "0"
EndSection
EOF

# Bluetooth : allumé au démarrage, reconnexion rapide, réappairage sans question des appareils connus
main_conf=/etc/bluetooth/main.conf
if [ -f "$main_conf" ]; then
  sed -E 's/^#?[[:space:]]*FastConnectable[[:space:]]*=.*/FastConnectable = true/;
          s/^#?[[:space:]]*JustWorksRepairing[[:space:]]*=.*/JustWorksRepairing = always/;
          s/^#?[[:space:]]*AutoEnable[[:space:]]*=.*/AutoEnable=true/' "$main_conf" > "$main_conf.scaros"
  if cmp -s "$main_conf" "$main_conf.scaros"; then
    rm -f "$main_conf.scaros"
  else
    mv -f "$main_conf.scaros" "$main_conf"
    systemctl restart bluetooth >/dev/null 2>&1 || true
  fi
fi
[ -f /etc/modprobe.d/scaros-xbox.conf ] || echo "options bluetooth disable_ertm=Y" > /etc/modprobe.d/scaros-xbox.conf
systemctl enable bluetooth >/dev/null 2>&1 || true

# applis ajoutées depuis l'installation
NEW_FLATPAKS=(com.valvesoftware.SteamLink)
for app in "${NEW_FLATPAKS[@]}"; do
  if ! flatpak info "$app" >/dev/null 2>&1; then
    echo "Installation de $app (quelques minutes)…"
    flatpak install -y --noninteractive flathub "$app" || echo "Installation de $app ratée : relance update.sh plus tard."
  fi
done
# décodage vidéo par la puce Intel pour les nouveaux runtimes
flatpak list --runtime --columns=application,branch 2>/dev/null | awk '$1=="org.freedesktop.Platform" {print $2}' | sort -u |
  while read -r branch; do
    flatpak install -y --noninteractive flathub "org.freedesktop.Platform.VAAPI.Intel//$branch" >/dev/null 2>&1 || true
  done

write_polkit_rule() {
  # le compte de la box gère Wi-Fi, Bluetooth, alimentation, applis et diagnostic réseau sans mot de passe
  mkdir -p /etc/polkit-1/rules.d
  cat > /etc/polkit-1/rules.d/50-scaros.rules <<EOF
// Scaros OS : le compte « $1 » pilote le Wi-Fi, l'alimentation, les applis et le diagnostic réseau depuis le menu.
polkit.addRule(function (action, subject) {
  if (subject.user != "$1") return;
  if (action.id.indexOf("org.freedesktop.NetworkManager.") == 0 ||
      action.id.indexOf("org.freedesktop.login1.") == 0 ||
      action.id.indexOf("org.freedesktop.Flatpak.") == 0) {
    return polkit.Result.YES;
  }
  if (action.id == "org.freedesktop.systemd1.manage-units" &&
      action.lookup("unit") == "scaros-diag.service" &&
      action.lookup("verb") == "start") {
    return polkit.Result.YES;
  }
});
EOF
}
USER_NAME="$(getent passwd 1000 | cut -d: -f1 || true)"
[ -n "$USER_NAME" ] && write_polkit_rule "$USER_NAME"

# diagnostic réseau lancé depuis le menu (Réglages › Wi-Fi › Diagnostic réseau), en root
cat > /etc/systemd/system/scaros-diag.service <<'EOF'
[Unit]
Description=Diagnostic réseau de Scaros OS

[Service]
Type=oneshot
ExecStart=/usr/local/bin/scaros-diag --service
TimeoutStartSec=180
EOF
systemctl daemon-reload

# Spotify Connect : spotifyd (programme officiel du projet, publié sur GitHub). « Scaros » apparaît alors
# dans la liste des appareils de l'appli Spotify (compte Premium) et le son sort par Scaros.
SPOTIFYD_URL="https://github.com/Spotifyd/spotifyd/releases/download/v0.4.2/spotifyd-linux-x86_64-full.tar.gz"
install_spotifyd() {
  [ -x /usr/local/bin/spotifyd ] && return 0
  local t; t="$(mktemp -d)"
  if wget -q -O "$t/spotifyd.tar.gz" "$SPOTIFYD_URL" && tar -xzf "$t/spotifyd.tar.gz" -C "$t" \
      && [ -n "$(find "$t" -type f -name spotifyd | head -n1)" ]; then
    install -m 755 "$(find "$t" -type f -name spotifyd | head -n1)" /usr/local/bin/spotifyd
    echo "Spotify Connect (spotifyd) installé."
  else
    echo "Attention : Téléchargement de spotifyd raté : Spotify Connect ne sera pas disponible (la musique du téléphone s'affichera quand même)."
  fi
  rm -rf "$t"
  if [ -x /usr/local/bin/spotifyd ] && ldd /usr/local/bin/spotifyd 2>/dev/null | grep -q "not found"; then
    echo "Attention : spotifyd : bibliothèques manquantes ($(ldd /usr/local/bin/spotifyd | grep 'not found' | awk '{print $1}' | xargs))."
  fi
}
# réglages de spotifyd pour le compte de la box (gardés s'ils existent déjà)
write_spotifyd_conf() {
  local home="$1" user="$2" conf="$1/.config/spotifyd/spotifyd.conf"
  [ -f "$conf" ] && return 0
  install -d -o "$user" -g "$user" "$home/.config" "$home/.config/spotifyd"
  cat > "$conf" <<'EOF'
# Scaros OS : Spotify Connect. « Scaros » dans la liste des appareils de l'appli Spotify.
[global]
device_name = "Scaros"
device_type = "t_v"
backend = "pulseaudio"
bitrate = 320
initial_volume = 90
volume_normalisation = true
use_mpris = true
dbus_type = "session"
EOF
  chown -R "$user:$user" "$home/.config/spotifyd"
}
install_spotifyd
[ -n "$USER_NAME" ] && write_spotifyd_conf "$(getent passwd "$USER_NAME" | cut -d: -f6)" "$USER_NAME"

# 3) fichiers de Scaros
mkdir -p /opt/scaros
rm -rf /opt/scaros/launcher /opt/scaros/system
cp -r "$src/launcher" "$src/system" /opt/scaros/
chmod 755 /opt/scaros/system/session.sh /opt/scaros/launcher/scaros.py /opt/scaros/launcher/osd.py
install -m 755 "$src/system/scaros-diag.sh" /usr/local/bin/scaros-diag
# polices du menu, aussi pour l'affichage par-dessus les applis
rm -rf /usr/local/share/fonts/scaros
mkdir -p /usr/local/share/fonts/scaros
cp "$src"/launcher/ui/fonts/*.woff2 /usr/local/share/fonts/scaros/ 2>/dev/null && fc-cache -f >/dev/null 2>&1 || true

# écran de démarrage (logo, animation) : remplacé s'il a changé
theme=/usr/share/plymouth/themes/scaros
if [ -d "$theme" ] && ! diff -rq "$src/system/plymouth/scaros" "$theme" >/dev/null 2>&1; then
  echo "Nouvel écran de démarrage…"
  rm -rf "$theme"
  cp -r "$src/system/plymouth/scaros" "$theme"
  update-initramfs -u >/dev/null 2>&1 || true
fi

status "done"
if [ -n "${need_reboot:-}" ]; then
  echo "Scaros est à jour. Le PC redémarre pour activer les nouveautés…"
  systemctl reboot
else
  echo "Scaros est à jour. L'écran redémarre…"
  systemctl restart getty@tty1
fi
