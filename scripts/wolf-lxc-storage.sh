#!/usr/bin/env bash
# Wolf Leader storage on the hub LXC: two local disks, one of them shared to every client.
#
#   mp1  (share disk)  /srv/wolf              the drive clients map (W:\ == \\wolf.local\wolf) — repos, vault, backups
#   mp2  (pg disk)     /var/lib/wolf-postgres Postgres only, never shared
#
# Run ON YOUR PROXMOX HOST (the node that owns the container):
#   WOLF_CT=<ctid> bash wolf-lxc-storage.sh            # dry run
#   WOLF_CT=<ctid> bash wolf-lxc-storage.sh --apply
#
# Prerequisite: the container already has its share disk attached as mp1 (any mount point).
# Touches only: that container's own config (mp1/mp2), its own volumes, files inside it.
set -euo pipefail

CT="${WOLF_CT:-}"
STORAGE="${WOLF_STORAGE:-local-lvm}"
PG_SIZE_GB="${WOLF_PG_SIZE_GB:-100}"
SHARE_MNT=/srv/wolf
PG_MNT=/var/lib/wolf-postgres
APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

[[ -n "$CT" ]] || { echo "refusing: set WOLF_CT=<ctid> (the hub container id)"; exit 1; }
command -v pct >/dev/null || { echo "refusing: pct not found — run this on the Proxmox host"; exit 1; }
pct status "$CT" >/dev/null 2>&1 || { echo "refusing: LXC $CT not on this node"; exit 1; }

cfg() { pct config "$CT" | awk -v k="$1" -F': ' '$1==k {print $2}'; }
vol() { echo "$1" | cut -d, -f1; }   # "local-lvm:vm-<ctid>-disk-1,mp=...,size=500G" -> volume id
MP1="$(cfg mp1)"; MP2="$(cfg mp2)"

echo "== current: mp1=[$MP1] mp2=[$MP2]"
[[ -n "$MP1" ]] || { echo "refusing: expected the share disk on mp1 (pct set $CT -mp1 $STORAGE:<GB>,mp=$SHARE_MNT)"; exit 1; }

# ---------------------------------------------------------------- 1. Postgres disk
if [[ -z "$MP2" ]]; then
  echo "== 1. add ${PG_SIZE_GB}G Postgres disk (mp2) at /mnt/pgnew, then move any existing pgdata onto it"
  if [[ $APPLY == 1 ]]; then
    pct exec "$CT" -- bash -c 'cd /opt/wolf-leader && docker compose -f docker-compose.postgres.yml stop' || true
    pct set "$CT" -mp2 "$STORAGE:$PG_SIZE_GB,mp=/mnt/pgnew,backup=1"
    pct reboot "$CT"
    for _ in $(seq 1 30); do pct exec "$CT" -- mountpoint -q /mnt/pgnew 2>/dev/null && break; sleep 2; done
    pct exec "$CT" -- bash -euo pipefail -c "
      mountpoint -q /mnt/pgnew
      if [ -f $PG_MNT/pgdata/PG_VERSION ]; then
        command -v rsync >/dev/null || (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync >/dev/null 2>&1)
        rsync -a $PG_MNT/pgdata /mnt/pgnew/
        test -f /mnt/pgnew/pgdata/PG_VERSION
        rm -rf $PG_MNT/pgdata $PG_MNT/lost+found
        echo 'pgdata moved to the new disk'
      fi
    "
    MP2="$(cfg mp2)"
  else
    echo "   would: stop stack; pct set $CT -mp2 $STORAGE:$PG_SIZE_GB,mp=/mnt/pgnew,backup=1; reboot; rsync existing pgdata"
  fi
fi

# ---------------------------------------------------------------- 2. remount: mp1 -> /srv/wolf, mp2 -> pgdata
NEED_REMAP=0
[[ "$MP1" == *"mp=$SHARE_MNT"* ]] || NEED_REMAP=1
[[ -n "$MP2" && "$MP2" == *"mp=$PG_MNT"* ]] || NEED_REMAP=1
if [[ $NEED_REMAP == 1 ]]; then
  echo "== 2. remap: mp1=$(vol "$MP1") -> $SHARE_MNT ; mp2=$(vol "${MP2:-<new>}") -> $PG_MNT"
  if [[ $APPLY == 1 ]]; then
    pct set "$CT" \
      -mp1 "$(vol "$MP1"),mp=$SHARE_MNT,backup=1,size=$(echo "$MP1" | sed -n 's/.*size=\([^,]*\).*/\1/p')" \
      -mp2 "$(vol "$MP2"),mp=$PG_MNT,backup=1,size=$(echo "$MP2" | sed -n 's/.*size=\([^,]*\).*/\1/p')"
    pct reboot "$CT"
    for _ in $(seq 1 30); do pct exec "$CT" -- mountpoint -q "$SHARE_MNT" 2>/dev/null && break; sleep 2; done
  else
    echo "   would: pct set $CT -mp1 <share disk>,mp=$SHARE_MNT -mp2 <pg disk>,mp=$PG_MNT; reboot"
  fi
else
  echo "== 2. mounts already correct"
fi

# ---------------------------------------------------------------- 3. Samba share + hub .env
echo "== 3. Samba share [wolf] = $SHARE_MNT inside LXC $CT; hub .env -> $SHARE_MNT / $PG_MNT"
if [[ $APPLY == 1 ]]; then
  pct exec "$CT" -- bash -euo pipefail -c "
    cd /opt/wolf-leader
    mountpoint -q $SHARE_MNT && mountpoint -q $PG_MNT
    mkdir -p $SHARE_MNT/wolf-leader/vault $SHARE_MNT/wolf-leader/hub
    export DEBIAN_FRONTEND=noninteractive
    command -v smbd >/dev/null || (apt-get update -qq && apt-get install -y -qq samba >/dev/null 2>&1)
    id -u wolf >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin wolf
    if grep -q '^WOLF_SHARE_PASSWORD=.\+' .env; then
      PW=\$(sed -n 's/^WOLF_SHARE_PASSWORD=//p' .env)
    else
      PW=\$(head -c 200 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | cut -c1-20)
      sed -i '/^WOLF_SHARE_USER=/d;/^WOLF_SHARE_PASSWORD=/d' .env
      printf '\nWOLF_SHARE_USER=wolf\nWOLF_SHARE_PASSWORD=%s\n' \"\$PW\" >> .env
    fi
    printf '%s\n%s\n' \"\$PW\" \"\$PW\" | smbpasswd -s -a wolf >/dev/null
    cat > /etc/samba/smb.conf <<'EOF'
[global]
   workgroup = WORKGROUP
   server string = Wolf Leader
   netbios name = WOLF
   server role = standalone server
   map to guest = never
   server min protocol = SMB2
   log file = /var/log/samba/log.%m
   max log size = 1000
   # everything the hub writes is root-owned; clients act as root on this one share
   # (LAN only, password protected; the share is the whole point of the box)
   vfs objects = fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba

[wolf]
   path = $SHARE_MNT
   comment = Wolf Leader drive: project repos, wolf-leader/vault (Obsidian), wolf-leader/hub (backups)
   browseable = yes
   read only = no
   valid users = wolf
   force user = root
   force group = root
   create mask = 0664
   directory mask = 0775
EOF
    systemctl enable --now smbd >/dev/null 2>&1 || true
    systemctl restart smbd
    # hub env
    grep -q '^WOLF_PGDATA=' .env && sed -i 's#^WOLF_PGDATA=.*#WOLF_PGDATA=$PG_MNT#' .env || printf '\nWOLF_PGDATA=%s\n' '$PG_MNT' >> .env
    grep -q '^WOLF_SHARE_ROOT=' .env && sed -i 's#^WOLF_SHARE_ROOT=.*#WOLF_SHARE_ROOT=$SHARE_MNT#' .env || printf 'WOLF_SHARE_ROOT=%s\n' '$SHARE_MNT' >> .env
    sed -i '/^IDE_STORAGE_SHARE_WINDOWS=/d;/^IDE_STORAGE_SHARE_NAS=/d;/^IDE_STORAGE_SHARE_UNC=/d;/^IDE_STORAGE_SHARE_MAC=/d' .env
    printf 'IDE_STORAGE_SHARE_WINDOWS=W:\\\\\nIDE_STORAGE_SHARE_UNC=\\\\\\\\wolf.local\\\\wolf\nIDE_STORAGE_SHARE_MAC=/Volumes/wolf\n' >> .env
    docker compose -f docker-compose.postgres.yml up -d
    sleep 25
    docker compose -f docker-compose.postgres.yml ps --format 'table {{.Name}}\t{{.Status}}'
    curl -s http://127.0.0.1:6971/health; echo
    echo; echo 'Map on Windows:  \\\\wolf.local\\wolf   user: wolf   password: see WOLF_SHARE_PASSWORD in /opt/wolf-leader/.env'
    df -h $SHARE_MNT $PG_MNT
  "
else
  echo "   would: install samba, user wolf (generated password saved to /opt/wolf-leader/.env), share [wolf]; rewrite .env; compose up"
fi

[[ $APPLY == 1 ]] || { echo; echo "dry run done — re-run with --apply"; }
