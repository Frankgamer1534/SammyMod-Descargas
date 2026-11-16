#!/usr/bin/env bash
# =============================================================================
#  Instalador del servidor Dedsafío Sammy Edition para Ubuntu Server (24.04+)
#
#  Uso (como root):
#     sudo bash instalar.sh                      # busca respaldo-dedsafio.zip en las USB
#     sudo bash instalar.sh /ruta/respaldo-dedsafio.zip
#
#  Qué hace:
#   - Instala Java 25 (Temurin) y lo necesario.
#   - Restaura tu servidor (mundo, configuración, EasyAuth, SkinRestorer...) desde el respaldo.
#   - Pone la última versión del mod Dedsafío desde SammyMod-Descargas.
#   - Deja el servidor como servicio: arranca solo al prender la PC y se reinicia si se cae.
#   - Copias del mundo automáticas cada 6 horas (guarda las 12 últimas).
#   - playit.gg con la misma dirección que tenías en Windows (si el respaldo trae playit.toml).
#   - La laptop no se suspende al cerrar la tapa.
#   - Comando "dedsafio" para manejarlo todo (dedsafio ayuda).
# =============================================================================
set -euo pipefail

BASE=/opt/dedsafio
SRV=$BASE/servidor
RESP=$BASE/respaldos
USUARIO=minecraft
DESCARGAS_REPO=Frankgamer1534/SammyMod-Descargas

verde() { printf '\033[1;32m%s\033[0m\n' "$*"; }
rojo()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
paso()  { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then rojo "Ejecútalo con sudo:  sudo bash $0"; exit 1; fi

# ----------------------------------------------------------------------------- respaldo
ZIP="${1:-}"
if [ -z "$ZIP" ]; then
  paso "Buscando respaldo-dedsafio.zip en las USB"
  ZIP=$(find /media /mnt -maxdepth 4 -iname 'respaldo-dedsafio.zip' 2>/dev/null | head -1 || true)
  if [ -z "$ZIP" ]; then
    mkdir -p /mnt/usb-dedsafio
    for part in $(lsblk -rpno NAME,TYPE,FSTYPE | awk '$2=="part" && ($3=="vfat"||$3=="exfat"||$3=="ntfs") {print $1}'); do
      if mountpoint -q /mnt/usb-dedsafio; then umount /mnt/usb-dedsafio || true; fi
      mount -o ro "$part" /mnt/usb-dedsafio 2>/dev/null || continue
      f=$(find /mnt/usb-dedsafio -maxdepth 3 -iname 'respaldo-dedsafio.zip' 2>/dev/null | head -1 || true)
      if [ -n "$f" ]; then ZIP="$f"; echo "Encontrado en $part"; break; fi
      umount /mnt/usb-dedsafio || true
    done
  fi
fi
if [ -z "$ZIP" ] || [ ! -f "$ZIP" ]; then
  rojo "No encontré respaldo-dedsafio.zip. Conecta la USB que lo tiene o pasa la ruta: sudo bash $0 /ruta/al/zip"
  exit 1
fi
verde "Respaldo: $ZIP"

# ----------------------------------------------------------------------------- paquetes
paso "Instalando programas (puede tardar unos minutos)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q curl wget unzip tar gnupg ca-certificates tmux jq apt-transport-https >/dev/null

if ! ls /usr/lib/jvm/temurin-25* >/dev/null 2>&1; then
  paso "Instalando Java 25"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor --yes -o /etc/apt/keyrings/adoptium.gpg
  CODENAME=$(. /etc/os-release; echo "${VERSION_CODENAME:-noble}")
  echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $CODENAME main" > /etc/apt/sources.list.d/adoptium.list
  apt-get update -q
  apt-get install -y -q temurin-25-jre >/dev/null 2>&1 || apt-get install -y -q temurin-25-jdk >/dev/null
fi
# usar siempre Java 25 aunque la PC tenga otra versión instalada
JAVA=$(ls -d /usr/lib/jvm/temurin-25*/bin/java 2>/dev/null | head -1 || true)
if [ -z "$JAVA" ]; then
  for j in /usr/lib/jvm/*/bin/java $(command -v java); do
    if "$j" -version 2>&1 | grep -q '"25'; then JAVA=$j; break; fi
  done
fi
if [ -z "$JAVA" ]; then rojo "No se pudo instalar Java 25."; exit 1; fi
"$JAVA" -version 2>&1 | head -1

# ----------------------------------------------------------------------------- usuario y archivos
paso "Restaurando tu servidor"
id -u $USUARIO >/dev/null 2>&1 || useradd --system --create-home --home-dir $BASE --shell /usr/sbin/nologin $USUARIO
mkdir -p "$SRV" "$RESP"
TMP=$(mktemp -d)
# los zip hechos en Windows (Compress-Archive) usan "\" en las rutas: se extrae con Python corrigiéndolas
python3 - "$ZIP" "$TMP" <<'PY'
import os, sys, zipfile, shutil
zip_path, destino = sys.argv[1], os.path.realpath(sys.argv[2])
with zipfile.ZipFile(zip_path) as z:
    for info in z.infolist():
        nombre = info.filename.replace("\\", "/")
        ruta = os.path.realpath(os.path.join(destino, nombre))
        if not ruta.startswith(destino + os.sep):
            continue
        if nombre.endswith("/"):
            os.makedirs(ruta, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(ruta), exist_ok=True)
        with z.open(info) as src, open(ruta, "wb") as dst:
            shutil.copyfileobj(src, dst)
PY
ORIGEN=$(find "$TMP" -maxdepth 2 -type f -name 'server.properties' -printf '%h\n' | head -1)
if [ -z "$ORIGEN" ]; then rojo "El respaldo no tiene server.properties; ¿es el zip correcto?"; exit 1; fi
if [ -d "$SRV/world" ]; then
  echo "Ya había un servidor: guardo una copia en $RESP/antes-de-restaurar.tar.gz"
  tar -czf "$RESP/antes-de-restaurar.tar.gz" -C "$SRV" . || true
fi
cp -a "$ORIGEN"/. "$SRV"/
rm -f "$SRV"/*.bat
PLAYIT_TOML=$(find "$TMP" -maxdepth 2 -type f -name 'playit.toml' | head -1 || true)
if [ -n "$PLAYIT_TOML" ]; then mkdir -p /etc/playit; cp "$PLAYIT_TOML" /etc/playit/playit.toml; chmod 600 /etc/playit/playit.toml; fi
rm -rf "$TMP"
echo "eula=true" > "$SRV/eula.txt"
# llave del servidor: sin ella el mod no deja arrancar el servidor
mkdir -p "$SRV/config"
if [ -n "${DEDSAFIO_LLAVE:-}" ]; then
  printf '%s\n' "$DEDSAFIO_LLAVE" > "$SRV/config/dedsafio_llave.txt"
elif [ ! -s "$SRV/config/dedsafio_llave.txt" ] && [ -t 0 ]; then
  read -r -p "Escribe la llave del servidor (te la dio Claude): " LL
  [ -n "$LL" ] && printf '%s\n' "$LL" > "$SRV/config/dedsafio_llave.txt"
fi
[ -f "$SRV/config/dedsafio_llave.txt" ] && chmod 600 "$SRV/config/dedsafio_llave.txt"
[ -s "$SRV/config/dedsafio_llave.txt" ] || rojo "Aviso: falta la llave del servidor. Ponla luego con: sudo dedsafio llave <clave>"

# ----------------------------------------------------------------------------- comando dedsafio
paso "Instalando el comando 'dedsafio'"
AQUI=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)
if [ -f "$AQUI/dedsafio" ]; then
  install -m 755 "$AQUI/dedsafio" /usr/local/bin/dedsafio
else
  curl -fsSL "https://raw.githubusercontent.com/$DESCARGAS_REPO/main/servidor/dedsafio" -o /usr/local/bin/dedsafio
  chmod 755 /usr/local/bin/dedsafio
fi
chmod 755 /usr/local/bin/dedsafio

# ----------------------------------------------------------------------------- mod actualizado
paso "Poniendo la última versión del mod"
URL=$(curl -fsSL "https://api.github.com/repos/$DESCARGAS_REPO/releases?per_page=10" | jq -r '[.[].assets[] | select(.name|endswith(".jar"))][0].browser_download_url' || true)
if [ -n "$URL" ] && [ "$URL" != "null" ]; then
  find "$SRV/mods" -maxdepth 1 -iname 'dedsafio*.jar' ! -iname 'dedsafio-staff*.jar' -delete
  curl -fsSL -o "$SRV/mods/$(basename "$URL")" "$URL" && verde "Mod: $(basename "$URL")"
else
  echo "No pude bajar el mod; se queda el del respaldo."
fi
ls -1 "$SRV/mods"
chown -R $USUARIO:$USUARIO "$BASE"

# ----------------------------------------------------------------------------- memoria
TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
RAM_MB=$(( TOTAL_MB - 900 ))
[ $RAM_MB -lt 1024 ] && RAM_MB=1024
[ $RAM_MB -gt 12288 ] && RAM_MB=12288
verde "RAM de la PC: ${TOTAL_MB} MB -> para Minecraft: ${RAM_MB} MB"

cat > $BASE/arrancar.sh <<EOS
#!/usr/bin/env bash
cd $SRV
tail -n 2000 $BASE/consola.log > $BASE/consola.log.tmp 2>/dev/null && mv $BASE/consola.log.tmp $BASE/consola.log
$JAVA -Xms${RAM_MB}M -Xmx${RAM_MB}M \\
  -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions \\
  -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 \\
  -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 \\
  -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:SurvivorRatio=32 \\
  -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 \\
  -jar fabric-server.jar nogui 2>&1 | tee -a $BASE/consola.log
EOS
chmod 755 $BASE/arrancar.sh
chown $USUARIO:$USUARIO $BASE/arrancar.sh

# distancia de visión más ligera para una PC con poca RAM
if [ "$TOTAL_MB" -lt 6000 ]; then
  sed -i 's/^view-distance=.*/view-distance=8/; s/^simulation-distance=.*/simulation-distance=6/' "$SRV/server.properties"
fi

# hasta 40 jugadores y el ícono del mod en la lista de servidores
if grep -q '^max-players=' "$SRV/server.properties"; then sed -i 's/^max-players=.*/max-players=40/' "$SRV/server.properties"; else echo "max-players=40" >> "$SRV/server.properties"; fi
curl -fsSL -o "$SRV/server-icon.png" "https://raw.githubusercontent.com/Frankgamer1534/SammyMod-Descargas/main/servidor/server-icon.png" || true
chown $USUARIO:$USUARIO "$SRV/server-icon.png" 2>/dev/null || true

# ----------------------------------------------------------------------------- servicio
paso "Dejando el servidor como servicio automático"
cat > /etc/systemd/system/dedsafio.service <<EOS
[Unit]
Description=Servidor Minecraft Dedsafio Sammy Edition
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=$USUARIO
WorkingDirectory=$SRV
Environment=SHELL=/bin/bash
ExecStart=/usr/bin/tmux -L dedsafio new-session -d -s dedsafio $BASE/arrancar.sh
ExecStop=-/usr/bin/tmux -L dedsafio send-keys -t dedsafio "stop" Enter
ExecStop=/bin/bash -c 'for i in \$(seq 1 60); do /usr/bin/tmux -L dedsafio has-session -t dedsafio 2>/dev/null || exit 0; sleep 1; done'
Restart=always
RestartSec=15
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
EOS

cat > /etc/systemd/system/dedsafio-respaldo.service <<EOS
[Unit]
Description=Copia del mundo de Dedsafio
[Service]
Type=oneshot
ExecStart=/usr/local/bin/dedsafio respaldo
EOS
cat > /etc/systemd/system/dedsafio-respaldo.timer <<EOS
[Unit]
Description=Copia del mundo de Dedsafio cada 6 horas
[Timer]
OnBootSec=30min
OnUnitActiveSec=6h
Persistent=true
[Install]
WantedBy=timers.target
EOS

# que el usuario normal pueda usar "dedsafio" sin pedir contraseña para estas órdenes
cat > /etc/sudoers.d/dedsafio <<EOS
%sudo ALL=(root) NOPASSWD: /usr/bin/systemctl start dedsafio, /usr/bin/systemctl stop dedsafio, /usr/bin/systemctl restart dedsafio
EOS
chmod 440 /etc/sudoers.d/dedsafio

# ----------------------------------------------------------------------------- laptop: no suspender
paso "Ajustes de la laptop"
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/dedsafio.conf <<EOS
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOS
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true
echo 'vm.swappiness=10' > /etc/sysctl.d/90-dedsafio.conf
sysctl -q -p /etc/sysctl.d/90-dedsafio.conf || true
systemctl restart systemd-logind || true

# ----------------------------------------------------------------------------- playit.gg
paso "playit.gg (para que tus jugadores entren)"
if ! command -v playit >/dev/null 2>&1; then
  curl -fsSL https://playit-cloud.github.io/ppa/key.gpg | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/playit.gpg
  echo "deb [signed-by=/etc/apt/trusted.gpg.d/playit.gpg] https://playit-cloud.github.io/ppa/data ./" > /etc/apt/sources.list.d/playit-cloud.list
  apt-get update -q
  apt-get install -y -q playit >/dev/null || rojo "No se pudo instalar playit; se puede hacer luego."
fi
if [ -f /etc/playit/playit.toml ]; then
  systemctl enable --now playit >/dev/null 2>&1 || true
  verde "playit usa la misma cuenta y dirección que en Windows."
else
  echo "No había playit.toml en el respaldo: ejecuta 'sudo playit setup' y abre el enlace que te da."
fi

# ----------------------------------------------------------------------------- encender
paso "Encendiendo el servidor"
systemctl daemon-reload
systemctl enable --now dedsafio.service
systemctl enable --now dedsafio-respaldo.timer
sleep 5
systemctl --no-pager status dedsafio | head -4 || true

verde ""
verde "=============================================================="
verde " ¡Listo! El servidor Dedsafío ya está encendido."
verde " Arranca solo cada vez que prendas la PC."
verde " Escribe:  dedsafio ayuda   para ver los comandos."
verde " La primera vez tarda 1-2 minutos en abrir el mundo:"
verde " míralo con:  dedsafio log"
verde "=============================================================="
