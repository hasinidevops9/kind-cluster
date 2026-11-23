#!/bin/bash
# Phase 1 updates the OS, grows the root disk, installs Docker, and schedules a reboot.
# Phase 2 runs only after that reboot, once Docker is accepting commands.
set -euo pipefail

export PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG=C

KIND_VERSION="v0.33.0"
K9S_VERSION="v0.51.0"
CLUSTER_NAME="${CLUSTER_NAME:-kind}"

log() {
  echo "[bootstrap] $*"
}

die() {
  echo "[bootstrap] ERROR: $*" >&2
  exit 1
}

wait_for_cloud_init() {
  if ! command -v cloud-init >/dev/null 2>&1; then
    die "cloud-init is not installed, so package installation cannot wait for first boot"
  fi
  log "Waiting for cloud-init to finish"
  cloud-init status --wait
  log "cloud-init status: $(cloud-init status)"
}

wait_for_dnf() {
  local attempt pid
  for attempt in $(seq 1 60); do
    if [[ ! -s /var/run/dnf.pid ]]; then
      return 0
    fi
    pid=$(cat /var/run/dnf.pid)
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    log "dnf pid ${pid} still holds the package lock (attempt ${attempt}/60)"
    sleep 5
  done
  die "dnf is still running; refusing to continue while the package lock is held"
}

assert_disk_space() {
  local min_gib="$1"
  local purpose="$2"
  local avail_kb min_kb avail_gib total_kb total_gib
  avail_kb=$(df -Pk /var | awk 'NR==2 {print $4}')
  total_kb=$(df -Pk /var | awk 'NR==2 {print $2}')
  min_kb=$((min_gib * 1024 * 1024))
  avail_gib=$((avail_kb / 1024 / 1024))
  total_gib=$((total_kb / 1024 / 1024))
  log "/var has ${avail_gib} GiB free (${total_gib} GiB total) before ${purpose}"
  if [[ "$avail_kb" -lt "$min_kb" ]]; then
    df -hT / /var >&2
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS >&2
    die "/var has ${avail_gib} GiB free; ${purpose} needs at least ${min_gib} GiB"
  fi
}

grow_filesystem() {
  local mountpoint="$1"
  local src fstype
  src=$(findmnt -n -o SOURCE "$mountpoint")
  fstype=$(findmnt -n -o FSTYPE "$mountpoint")
  [[ -n "$src" && -n "$fstype" ]] || die "could not identify the filesystem mounted at ${mountpoint}"
  log "Growing ${fstype} filesystem on ${mountpoint} (${src})"
  case "$fstype" in
    xfs) xfs_growfs "$mountpoint" ;;
    ext4 | ext3) resize2fs "$src" ;;
    *) die "unsupported filesystem ${fstype} on ${mountpoint}" ;;
  esac
}

block_type() {
  local dev="$1" type
  type=$(lsblk -dn -o TYPE "$dev" | awk '{print $1}')
  [[ -n "$type" ]] || die "could not read the block type of ${dev}"
  printf '%s\n' "$type"
}

parent_disk_of() {
  local dev="$1" type parent
  dev=$(readlink -f "$dev")
  type=$(block_type "$dev")
  while [[ "$type" == "part" ]]; do
    parent=$(lsblk -dn -o PKNAME "$dev" | awk '{print $1}')
    [[ -n "$parent" ]] || die "partition ${dev} has no parent disk"
    dev="/dev/${parent}"
    type=$(block_type "$dev")
  done
  [[ "$type" == "disk" ]] || die "device ${dev} resolved to type ${type}, not a disk"
  [[ -b "$dev" ]] || die "disk ${dev} is not a block device"
  printf '%s\n' "$dev"
}

# Disks that actually hold the filesystem at mountpoint.
# An LVM logical volume is followed through lsblk's dependency list.
# Other logical volumes in the same volume group are not included.
disks_for_mount() {
  local mountpoint="$1" src dev type name typ
  local -a disks=()
  src=$(findmnt -n -o SOURCE "$mountpoint")
  [[ -n "$src" ]] || die "could not find the device mounted at ${mountpoint}"
  dev=$(readlink -f "$src")
  [[ -e "$dev" ]] || die "device ${dev} for ${mountpoint} does not exist"
  type=$(block_type "$dev")
  if [[ "$type" == "lvm" ]]; then
    while read -r name typ; do
      [[ "$typ" == "disk" ]] || continue
      disks+=("/dev/${name}")
    done < <(lsblk -sln -o NAME,TYPE "$dev")
  elif [[ "$type" == "part" || "$type" == "disk" ]]; then
    disks+=("$(parent_disk_of "$dev")")
  else
    die "unsupported device type ${type} for ${mountpoint} (${dev})"
  fi
  [[ "${#disks[@]}" -ge 1 ]] || die "could not find a disk backing ${mountpoint} (${dev})"
  if [[ "${#disks[@]}" -gt 1 ]]; then
    die "${mountpoint} (${dev}) spans multiple disks: ${disks[*]}"
  fi
  [[ -b "${disks[0]}" ]] || die "disk ${disks[0]} for ${mountpoint} is not a block device"
  printf '%s\n' "${disks[0]}"
}

detect_host_root_disk() {
  disks_for_mount /
}

save_host_root_disk() {
  local disk
  disk=$(detect_host_root_disk)
  install -d -m 0755 /var/lib
  printf '%s\n' "$disk" >/var/lib/bootstrap-root-disk
  chmod 644 /var/lib/bootstrap-root-disk
  log "Host root device for Kind is ${disk}"
}

wait_for_disk_size() {
  local disk="$1" min_bytes="$2" short rescan attempt size
  short="${disk#/dev/}"
  rescan="/sys/class/block/${short}/device/rescan"
  if [[ -w "$rescan" ]]; then
    log "Rescanning ${disk}"
    if ! echo 1 >"$rescan"; then
      size=$(lsblk -bdn -o SIZE "$disk")
      if [[ "$size" -lt "$min_bytes" ]]; then
        die "rescan of ${disk} failed and the disk is ${size} bytes"
      fi
      log "Rescan of ${disk} failed, but the disk is already ${size} bytes"
    fi
  fi
  for attempt in $(seq 1 30); do
    size=$(lsblk -bdn -o SIZE "$disk")
    if [[ "$size" -ge "$min_bytes" ]]; then
      log "Disk ${disk} is ${size} bytes"
      return 0
    fi
    log "Disk ${disk} is ${size} bytes; waiting for at least ${min_bytes} bytes (attempt ${attempt}/30)"
    if [[ "$attempt" -eq 30 ]]; then
      die "disk ${disk} stayed at ${size} bytes, below the required ${min_bytes} bytes"
    fi
    sleep 2
  done
}

grow_partition() {
  local disk="$1" partnum="$2" grow_rc
  command -v growpart >/dev/null 2>&1 || die "growpart is not installed"
  # growpart: 0 = partition grew, 1 = already at full size, 2 = failure.
  set +e
  growpart "$disk" "$partnum"
  grow_rc=$?
  set -e
  if [[ "$grow_rc" -eq 0 ]]; then
    log "Grew partition ${partnum} on ${disk}"
  elif [[ "$grow_rc" -eq 1 ]]; then
    log "Partition ${partnum} on ${disk} is already fully grown"
  else
    die "growpart ${disk} ${partnum} failed with exit code ${grow_rc}"
  fi
}

lv_size_bytes() {
  local lv="$1" size
  size=$(lvs --noheadings --units b --nosuffix -o lv_size "$lv" | awk '{print int($1)}')
  [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || die "could not read the size of logical volume ${lv}"
  printf '%s\n' "$size"
}

extend_separate_var_lv() {
  local lv="$1" vg="$2"
  local baseline_file="/var/lib/bootstrap-var-baseline"
  local ten_gib current baseline target free_bytes new_size
  ten_gib=$((10 * 1024 * 1024 * 1024))
  current=$(lv_size_bytes "$lv")
  if [[ -f "$baseline_file" ]]; then
    baseline=$(tr -d '[:space:]' <"$baseline_file")
    [[ "$baseline" =~ ^[0-9]+$ ]] || die "invalid /var baseline in ${baseline_file}"
    target=$((baseline + ten_gib))
    if [[ "$current" -ge "$target" ]]; then
      log "/var logical volume is ${current} bytes, already at or above target ${target}"
      return 0
    fi
    log "/var logical volume is ${current} bytes; extending it to ${target}"
  else
    # Record the size before lvextend. A later run can see the growth even
    # when this function is interrupted before it returns.
    printf '%s\n' "$current" >"$baseline_file"
    chmod 644 "$baseline_file"
    sync
    baseline=$current
    target=$((baseline + ten_gib))
    log "Recorded /var baseline ${baseline}; target after adding 10 GiB is ${target}"
  fi
  free_bytes=$(vgs --noheadings --units b --nosuffix -o vg_free "$vg" | awk '{print int($1)}')
  [[ "$free_bytes" -ge $((target - current)) ]] || die "need $((target - current)) bytes free in ${vg} to reach ${target}; found ${free_bytes}"
  lvextend -L "${target}B" "$lv"
  new_size=$(lv_size_bytes "$lv")
  [[ "$new_size" -ge "$target" ]] || die "lvextend left ${lv} at ${new_size} bytes, below target ${target}"
  log "/var logical volume is now ${new_size} bytes"
}

expand_var_storage() {
  local var_src var_real root_real dev_type
  var_src=$(findmnt -n -o SOURCE /var)
  root_real=$(readlink -f "$(findmnt -n -o SOURCE /)")
  [[ -n "$var_src" && -n "$root_real" ]] || die "could not find the devices mounted at / and /var"
  var_real=$(readlink -f "$var_src")
  dev_type=$(block_type "$var_real")
  log "/var is ${var_src} (${var_real}, type ${dev_type}); root filesystem device is ${root_real}"

  if [[ "$dev_type" == "lvm" ]]; then
    local vg pv_name pv_dev pv_type pv_disk partnum free_bytes
    vg=$(lvs --noheadings -o vg_name "$var_src" | awk '{print $1}')
    [[ -n "$vg" ]] || die "/var logical volume has no volume group"
    local -a pvs=()
    while read -r pv_name; do
      [[ -n "$pv_name" ]] || continue
      pvs+=("$pv_name")
    done < <(pvs --noheadings -o pv_name,vg_name | awk -v vg="$vg" '$2 == vg {print $1}')
    [[ "${#pvs[@]}" -ge 1 ]] || die "volume group ${vg} has no physical volumes"
    for pv_name in "${pvs[@]}"; do
      pv_dev=$(readlink -f "$pv_name")
      pv_type=$(block_type "$pv_dev")
      log "Volume group ${vg} physical volume ${pv_dev} (${pv_type})"
      if [[ "$pv_type" == "part" ]]; then
        pv_disk=$(parent_disk_of "$pv_dev")
        partnum=$(printf '%s\n' "$pv_dev" | grep -oE '[0-9]+$')
        [[ -n "$partnum" ]] || die "could not read the partition number of ${pv_dev}"
        wait_for_disk_size "$pv_disk" 1
        grow_partition "$pv_disk" "$partnum"
      elif [[ "$pv_type" == "disk" ]]; then
        wait_for_disk_size "$pv_dev" 1
      else
        die "unsupported physical volume type ${pv_type} for ${pv_dev}"
      fi
      pvresize "$pv_dev"
    done
    free_bytes=$(vgs --noheadings --units b --nosuffix -o vg_free "$vg" | awk '{print int($1)}')
    log "Volume group ${vg} has ${free_bytes} bytes free after pvresize"
    if [[ "$var_real" != "$root_real" ]]; then
      extend_separate_var_lv "$var_src" "$vg"
    elif [[ "$free_bytes" -gt 0 ]]; then
      log "Root and /var share ${var_src}; assigning the free space in ${vg} to that logical volume"
      lvextend -l +100%FREE "$var_src"
    else
      log "Shared logical volume ${var_src} already uses the free space in ${vg}"
    fi
  elif [[ "$dev_type" == "part" ]]; then
    local disk partnum
    disk=$(parent_disk_of "$var_real")
    partnum=$(printf '%s\n' "$var_real" | grep -oE '[0-9]+$')
    [[ -n "$partnum" ]] || die "could not read the partition number of ${var_real}"
    wait_for_disk_size "$disk" 1
    grow_partition "$disk" "$partnum"
  elif [[ "$dev_type" == "disk" ]]; then
    wait_for_disk_size "$var_real" 1
  else
    die "unsupported /var device type ${dev_type} for ${var_real}"
  fi

  grow_filesystem /var
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
}

expand_storage() {
  local root_disk min_bytes
  save_host_root_disk
  root_disk=$(detect_host_root_disk)
  min_bytes=$((38 * 1024 * 1024 * 1024))
  wait_for_disk_size "$root_disk" "$min_bytes"
  expand_var_storage
}

configure_os_for_kind() {
  log "Configuring kernel modules and sysctl for Kind"
  cat >/etc/modules-load.d/kind.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter

  {
    echo "net.bridge.bridge-nf-call-iptables = 1"
    echo "net.ipv4.ip_forward = 1"
    echo "fs.inotify.max_user_watches = 524288"
    echo "fs.inotify.max_user_instances = 512"
    if [[ -e /proc/sys/net/bridge/bridge-nf-call-ip6tables ]]; then
      echo "net.bridge.bridge-nf-call-ip6tables = 1"
    fi
  } >/etc/sysctl.d/99-kind.conf
  sysctl -p /etc/sysctl.d/99-kind.conf >/dev/null

  if [[ -f /etc/selinux/config ]]; then
    if grep -q '^SELINUX=' /etc/selinux/config; then
      sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
    else
      echo 'SELINUX=permissive' >>/etc/selinux/config
    fi
  fi
  if command -v getenforce >/dev/null 2>&1; then
    local mode
    mode=$(getenforce)
    log "SELinux is ${mode}"
    if [[ "$mode" == "Enforcing" ]]; then
      setenforce 0
    fi
  fi

  if systemctl list-unit-files firewalld.service --no-legend | grep -q '^firewalld.service'; then
    log "Disabling firewalld so Docker and Kind can manage networking"
    systemctl disable --now firewalld
  fi
}

install_docker() {
  local os_id os_like repo
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  os_like="${ID_LIKE:-}"
  case "$os_id" in
    rhel)
      repo="https://download.docker.com/linux/rhel/docker-ce.repo"
      ;;
    centos | rocky | almalinux)
      repo="https://download.docker.com/linux/centos/docker-ce.repo"
      ;;
    *)
      if [[ "$os_like" == *rhel* ]]; then
        repo="https://download.docker.com/linux/rhel/docker-ce.repo"
      else
        die "unsupported OS ID=${os_id} ID_LIKE=${os_like}"
      fi
      ;;
  esac
  log "Installing Docker CE for ${PRETTY_NAME:-$os_id} from ${repo}"

  dnf install -y dnf-plugins-core
  dnf config-manager --add-repo "$repo"
  dnf install -y --allowerasing \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
  rpm -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null || die "docker packages are missing after installation"

  mkdir -p /etc/docker
  cat >/etc/docker/daemon.json <<'EOF'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

  local ssh_user="${SUDO_USER:-}"
  [[ -n "$ssh_user" && "$ssh_user" != "root" ]] || die "phase1 must be started with sudo from the SSH user"
  usermod -aG docker "$ssh_user"
  id "$ssh_user" | grep -q '(docker)' || die "failed to add ${ssh_user} to the docker group"

  systemctl enable docker
  systemctl restart docker
  if ! systemctl is-active --quiet docker; then
    set +e
    systemctl --no-pager --full status docker >&2
    journalctl -u docker -n 80 --no-pager >&2
    set -e
    die "docker service is not active after installation"
  fi
  docker info >/dev/null || die "docker info failed after installation"
  docker --version
  log "Docker is installed and answering before the reboot"
}

schedule_reboot() {
  local boot_id unit timer_output timer_rc
  boot_id=$(cat /proc/sys/kernel/random/boot_id)
  install -d -m 0755 /var/lib
  printf '%s\n' "$boot_id" >/var/lib/bootstrap-boot-id
  chmod 644 /var/lib/bootstrap-boot-id
  sync

  unit="bootstrap-reboot-${boot_id%%-*}"
  log "Scheduling reboot in 20 seconds so this SSH session can exit first"
  set +e
  timer_output=$(systemd-run --collect --on-active=20s --unit="$unit" /bin/systemctl reboot 2>&1)
  timer_rc=$?
  set -e
  log "$timer_output"
  [[ "$timer_rc" -eq 0 ]] || die "systemd-run failed to schedule the reboot"
  [[ "$timer_output" == *timer* ]] || die "systemd-run did not schedule a reboot timer: ${timer_output}"
  log "Reboot is scheduled. Current boot id ${boot_id} was saved."
}

require_new_boot() {
  [[ -f /var/lib/bootstrap-boot-id ]] || die "reboot marker is missing; phase1 did not finish"
  local old new
  old=$(cat /var/lib/bootstrap-boot-id)
  new=$(cat /proc/sys/kernel/random/boot_id)
  [[ -n "$old" && -n "$new" && "$old" != "$new" ]] || die "this boot matches the pre-Docker-install boot; refusing to create the Kind cluster"
  log "Running on a new boot (${new})"
}

require_docker_ready() {
  local attempt max_attempts=30 group_ok service_ok info_ok
  for attempt in $(seq 1 "$max_attempts"); do
    group_ok=0
    service_ok=0
    info_ok=0
    if id -nG | tr ' ' '\n' | grep -qx docker; then
      group_ok=1
    fi
    if systemctl is-active --quiet docker; then
      service_ok=1
    fi
    if docker info >/dev/null 2>&1; then
      info_ok=1
    fi
    if [[ "$group_ok" -eq 1 && "$service_ok" -eq 1 && "$info_ok" -eq 1 ]]; then
      docker --version
      log "Docker is ready for Kind"
      return 0
    fi
    log "Waiting for Docker (attempt ${attempt}/${max_attempts}): group=${group_ok} service=${service_ok} info=${info_ok}"
    if [[ "$attempt" -eq "$max_attempts" ]]; then
      set +e
      id -nG >&2
      systemctl --no-pager --full status docker >&2
      docker info >&2
      set -e
      die "Docker did not become ready for $(id -un) within 5 minutes"
    fi
    sleep 10
  done
}

install_user_bin() {
  local src="$1"
  local name="$2"
  sudo -n install -d -m 0755 /usr/local/bin
  sudo -n install -m 0755 "$src" "/usr/local/bin/${name}"
  hash -r
}

install_cli() {
  local url dest kver
  if ! command -v kind >/dev/null 2>&1 || ! kind version 2>/dev/null | grep -q "$KIND_VERSION"; then
    url="https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    dest="/tmp/kind"
    log "Installing Kind ${KIND_VERSION}"
    curl -fL --retry 5 --retry-delay 2 -o "$dest" "$url"
    install_user_bin "$dest" kind
  fi
  kind version | grep -q "$KIND_VERSION" || die "kind version check failed: $(kind version 2>&1)"

  log "Installing the current stable kubectl"
  curl -fL --retry 5 --retry-delay 2 -o /tmp/kubectl-version.txt https://dl.k8s.io/release/stable.txt
  kver=$(tr -d '[:space:]' </tmp/kubectl-version.txt)
  [[ "$kver" == v* ]] || die "unexpected kubectl stable version '${kver}'"
  curl -fL --retry 5 --retry-delay 2 -o /tmp/kubectl "https://dl.k8s.io/release/${kver}/bin/linux/amd64/kubectl"
  install_user_bin /tmp/kubectl kubectl
  kubectl version --client -o json | grep -q '"clientVersion"' || die "kubectl client did not print a version"

  if ! command -v k9s >/dev/null 2>&1 || ! k9s version 2>/dev/null | grep -q "${K9S_VERSION#v}"; then
    log "Installing k9s ${K9S_VERSION}"
    curl -fL --retry 5 --retry-delay 2 -o /tmp/k9s.tar.gz \
      "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz"
    tar -xzf /tmp/k9s.tar.gz -C /tmp k9s
    install_user_bin /tmp/k9s k9s
  fi
  k9s version | grep -q "${K9S_VERSION#v}" || die "k9s version check failed"
}

node_container_state() {
  local name="$1" out rc
  set +e
  out=$(docker inspect -f '{{.State.Status}}' "$name" 2>&1)
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    printf '%s\n' "$out"
    return 0
  fi
  if [[ "$out" == *"such object"* || "$out" == *"No such"* || "$out" == *"not found"* ]]; then
    printf 'absent\n'
    return 0
  fi
  die "docker inspect ${name} failed: ${out}"
}

create_kind_cluster() {
  local config="${HOME}/kind-config.yaml"
  local root_disk saved_root
  mkdir -p "${HOME}/.kube"
  export KUBECONFIG="${HOME}/.kube/config"

  root_disk=$(detect_host_root_disk)
  [[ -b "$root_disk" ]] || die "host root device ${root_disk} is not a block device"
  [[ "$root_disk" =~ ^/dev/[A-Za-z0-9._/-]+$ ]] || die "refusing unsafe host root device path ${root_disk}"
  if [[ -r /var/lib/bootstrap-root-disk ]]; then
    saved_root=$(tr -d '[:space:]' </var/lib/bootstrap-root-disk)
    [[ "$saved_root" == "$root_disk" ]] || die "saved root device ${saved_root} does not match the device backing / (${root_disk})"
  fi
  log "Kind will mount host root device ${root_disk}"

  cat >"$config" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: ${root_disk}
        containerPath: ${root_disk}
        readOnly: false
        selinuxRelabel: false
EOF

  local node_name="${CLUSTER_NAME}-control-plane"
  local clusters mounts container_state has_cluster=false
  clusters=$(kind get clusters)
  if printf '%s\n' "$clusters" | grep -qx "$CLUSTER_NAME"; then
    has_cluster=true
  fi
  container_state=$(node_container_state "$node_name")

  if [[ "$has_cluster" == false && "$container_state" != absent ]]; then
    log "Removing orphaned Kind container ${node_name} before creating the cluster"
    docker rm -f "$node_name"
    container_state=absent
  fi

  if [[ "$has_cluster" == true && "$container_state" == absent ]]; then
    log "Kind cluster record exists without a node container; recreating it"
    kind delete cluster --name "$CLUSTER_NAME"
    kind create cluster --name "$CLUSTER_NAME" --config "$config" --wait 300s
  elif [[ "$has_cluster" == true ]]; then
    if [[ "$container_state" != running ]]; then
      log "Starting the existing Kind node container"
      docker start "$node_name"
      container_state=$(node_container_state "$node_name")
      [[ "$container_state" == running ]] || die "Kind container ${node_name} is ${container_state}"
    fi
    mounts=$(docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$node_name")
    if ! printf '%s\n' "$mounts" | grep -qx "$root_disk"; then
      log "Kind node is missing the host root device mount; recreating the cluster"
      kind delete cluster --name "$CLUSTER_NAME"
      kind create cluster --name "$CLUSTER_NAME" --config "$config" --wait 300s
    elif ! kubectl wait --for=condition=Ready node --all --timeout=180s; then
      log "Existing cluster did not become Ready; recreating it"
      kind delete cluster --name "$CLUSTER_NAME"
      kind create cluster --name "$CLUSTER_NAME" --config "$config" --wait 300s
    else
      log "Kind cluster ${CLUSTER_NAME} already exists and its node is Ready"
    fi
  else
    kind create cluster --name "$CLUSTER_NAME" --config "$config" --wait 300s
  fi

  kubectl wait --for=condition=Ready node --all --timeout=300s
  kubectl get nodes -o wide

  local ready_count total_count
  ready_count=$(kubectl get nodes --no-headers | awk '$2 == "Ready" {count++} END {print count + 0}')
  total_count=$(kubectl get nodes --no-headers | awk 'END {print NR + 0}')
  [[ "$total_count" -eq 1 ]] || die "expected one Kind node, found ${total_count}"
  [[ "$ready_count" -eq 1 ]] || die "the Kind node is not Ready"
  log "Kind cluster ${CLUSTER_NAME} has one Ready node"
}

phase1() {
  [[ "$(id -u)" -eq 0 ]] || die "phase1 must run as root"
  [[ "$(uname -m)" == "x86_64" ]] || die "expected x86_64, found $(uname -m)"
  wait_for_cloud_init
  wait_for_dnf
  dnf install -y cloud-utils-growpart lvm2 xfsprogs e2fsprogs
  expand_storage
  assert_disk_space 8 "Docker installation"
  configure_os_for_kind
  install_docker
  schedule_reboot
  log "Phase 1 finished. The instance will reboot before Kind is installed."
}

phase2() {
  [[ "$(id -u)" -ne 0 ]] || die "phase2 must run as the SSH user, not root"
  [[ "$(uname -m)" == "x86_64" ]] || die "expected x86_64, found $(uname -m)"
  wait_for_cloud_init
  require_new_boot
  require_docker_ready
  assert_disk_space 8 "Kind image download"
  install_cli
  create_kind_cluster
}

case "${1:-}" in
  phase1) phase1 ;;
  phase2) phase2 ;;
  *) die "usage: $0 phase1|phase2" ;;
esac
