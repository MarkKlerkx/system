#!/usr/bin/env bash
# ==============================================================================
# Ubuntu 26.04 Server (Minimal) - Docker Setup & Opslag Optimalisatie Script
# Description: Installeert Docker, configureert /dev/sda (Kingston SSD) als 
#              exclusieve Docker data-root, en past OS-optimalisaties toe.
# ==============================================================================

# Sluit direct af bij fouten of ongedefinieerde variabelen
set -euo pipefail

# Controleer of het script als root wordt uitgevoerd
if [ "$EUID" -ne 0 ]; then
    echo "Fout: Dit script moet als root (via sudo) worden uitgevoerd." >&2
    exit 1
fi

echo "====================================================================="
echo " Starten van Ubuntu 26.04 Server Docker & Opslag Optimalisatie"
echo " (Geoptimaliseerd voor Minimal Installations)"
echo "====================================================================="

# ------------------------------------------------------------------------------
# Stap 1: Systeem vooraf updaten en ontbrekende basistools installeren
# ------------------------------------------------------------------------------
echo -e "\n[Stap 1/6] Systeem updaten en ontbrekende systeemtools installeren..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# Installeer tools die vaak ontbreken in de minimale installatie
echo "Basistools installeren (parted, rsync, curl, gnupg, lsb-release)..."
apt-get install -y parted rsync curl gnupg lsb-release ca-certificates

# Restanten en overbodige pakketten direct opschonen
apt-get autoremove -y --purge
apt-get clean -y

# ------------------------------------------------------------------------------
# Stap 2: Slimme schijfdetectie & formatteren van sda
# ------------------------------------------------------------------------------
echo -e "\n[Stap 2/6] Schijfdetectie en formattering..."
echo "Huidige opslagapparaten op dit systeem:"
lsblk -o NAME,FSTYPE,SIZE,LABEL,MOUNTPOINTS,MODEL

# Bepaal de meest voor de hand liggende extra SSD (Kingston SATA is vrijwel altijd /dev/sda)
SUGGESTED_DISK="/dev/sda"

echo -e "\n--------------------------------------------------"
echo "Suggestie: De schijf '$SUGGESTED_DISK' (Kingston SATA SSD 460GB)"
echo "is geselecteerd om volledig geformatteerd te worden voor Docker."
echo "--------------------------------------------------"

read -p "Wilt u doorgaan met schijf $SUGGESTED_DISK? ALLE DATA OP DEZE SCHIJF WORDT GEWIST! (ja/nee): " CONFIRM
if [ "$CONFIRM" != "ja" ]; then
    echo "Installatie afgebroken door gebruiker."
    exit 1
fi

# Indien de schijf per ongeluk gemount is, koppel hem los
if mount | grep -q "^$SUGGESTED_DISK"; then
    echo "Schijf $SUGGESTED_DISK is momenteel gemount. Afkoppelen..."
    umount -l "$SUGGESTED_DISK"* || true
fi

echo "Schijf $SUGGESTED_DISK volledig leegmaken en partitioneren met GPT..."
parted -s "$SUGGESTED_DISK" mklabel gpt
parted -s -a optimal "$SUGGESTED_DISK" mkpart primary ext4 0% 100%

PARTITION="${SUGGESTED_DISK}1"
echo "Partitie $PARTITION formatteren naar Ext4..."
mkfs.ext4 -F "$PARTITION"

# ------------------------------------------------------------------------------
# Stap 3: Map /docker aanmaken en persistent mounten via fstab
# ------------------------------------------------------------------------------
echo -e "\n[Stap 3/6] Map /docker aanmaken en persistent koppelen..."
mkdir -p /docker

# UUID ophalen voor stabiele fstab-koppeling
UUID=$(blkid -o value -s UUID "$PARTITION")
echo "UUID van de nieuwe partitie is: $UUID"

# Schijf toevoegen aan /etc/fstab met performance-optimalisaties (noatime)
if ! grep -q "$UUID" /etc/fstab; then
    echo "Toevoegen aan /etc/fstab..."
    echo "UUID=$UUID /docker ext4 defaults,noatime,nodiratime,errors=remount-ro 0 2" >> /etc/fstab
fi

echo "Mounten van de nieuwe schijf op /docker..."
mount -a

# ------------------------------------------------------------------------------
# Stap 4: Docker installeren (Officiële Docker-CE Repository)
# ------------------------------------------------------------------------------
echo -e "\n[Stap 4/6] Docker Engine installeren..."

# GPG-sleutel toevoegen
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes

# Repository toevoegen
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Docker direct stoppen om de data-root configuratie toe te passen
systemctl stop docker

# ------------------------------------------------------------------------------
# Stap 5: Docker configureren met data-root op /docker & Log-rotatie
# ------------------------------------------------------------------------------
echo -e "\n[Stap 5/6] Docker data-root en log-limieten instellen..."
mkdir -p /etc/docker

# Instellen van data-root én log-rotatie om te voorkomen dat SSD's ongemerkt vollopen met containerlogs
cat <<EOF > /etc/docker/daemon.json
{
  "data-root": "/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF

# Start en activeer Docker opnieuw
systemctl daemon-reload
systemctl start docker
systemctl enable docker

# ------------------------------------------------------------------------------
# Stap 6: Systeem-breed performance optimalisaties doorvoeren (Sysctl & TRIM)
# ------------------------------------------------------------------------------
echo -e "\n[Stap 6/6] Systeem optimalisaties toepassen..."

# Sysctl optimalisaties voor zware netwerk/database I/O in containers
cat <<EOF > /etc/sysctl.d/99-docker-performance.conf
# Maximaal aantal open bestanden verhogen
fs.file-max = 2097152

# Virtueel geheugenlimiet verhogen (nodig voor Elasticsearch, databases etc.)
vm.max_map_count = 262144

# Netwerk socket queue vergroten voor betere load-afhandeling
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 2048

# Swappiness verlagen naar 10 om onnodig swappen naar SSD te voorkomen
vm.swappiness = 10
EOF

# Direct toepassen van sysctl wijzigingen
sysctl --system

# SSD wekelijkse TRIM activeren (cruciaal voor behoud van snelheid van beide SSD's)
echo "Activeren van wekelijkse TRIM (fstrim.timer)..."
systemctl enable --now fstrim.timer

echo -e "\n====================================================================="
echo " Installatie en Optimalisatie Succesvol Voltooid!"
echo "====================================================================="
echo " - Je systeem is up-to-date en overbodige pakketresten zijn verwijderd."
echo " - Schijf $SUGGESTED_DISK is geformatteerd en gekoppeld op /docker."
echo " - Alle Docker containers, images en volumes worden opgeslagen in /docker."
echo " - Kernel-parameters zijn geoptimaliseerd voor database/netwerk-workloads."
echo " - Log-rotatie is actief (max 3 logs van 10MB per container)."
echo "====================================================================="
docker info | grep -E "Docker Root Dir|Storage Driver"
