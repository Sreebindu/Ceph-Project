#!/usr/bin/env bash
# Rook-Ceph RGW deployment on kind with NBD-backed OSDs.
# Modes:
#   bash deploy_fixed.sh                  # normal deploy/resume (non-destructive)
#   bash deploy_fixed.sh --reinstall      # clean Ceph/kind/NBD state, then deploy fresh
#   bash deploy_fixed.sh --cleanup-only   # remove Ceph/kind/NBD state and exit
#   bash deploy_fixed.sh --bootstrap      # install missing host prerequisites, then deploy
#
# IMPORTANT: --reinstall and --cleanup-only DELETE the Ceph data stored in
# /var/lib/rook-loop-disks. They are intended for detached/unknown/broken OSD lab rebuilds.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CLUSTER_NAME="${CLUSTER_NAME:-rook-ceph}"
NAMESPACE="${NAMESPACE:-rook-ceph}"
DISK_DIR="${DISK_DIR:-/var/lib/rook-loop-disks}"
DISK_SIZE="${DISK_SIZE:-20G}"
EXPECTED_OSDS="${EXPECTED_OSDS:-3}"
RGW_PORT="${RGW_PORT:-7480}"
DASHBOARD_PORT="${DASHBOARD_PORT:-7000}"
S3_BUCKET="${S3_BUCKET:-pcaps}"
KIND_VERSION="${KIND_VERSION:-v0.33.0}"
ROOK_TOOLBOX_URL="${ROOK_TOOLBOX_URL:-https://raw.githubusercontent.com/rook/rook/master/deploy/examples/toolbox.yaml}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
mkdir -p "$LOG_DIR"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
if [ -n "${SUDO_USER:-}" ]; then
  export KUBECONFIG="/home/${SUDO_USER}/.kube/config"
fi

MODE="deploy"
BOOTSTRAP=false
for arg in "$@"; do
  case "$arg" in
    --reinstall) MODE="reinstall" ;;
    --cleanup-only) MODE="cleanup" ;;
    --bootstrap) BOOTSTRAP=true ;;
    -h|--help)
      sed -n '1,12p' "$0"
      exit 0
      ;;
    *) echo "ERROR: Unknown argument: $arg"; exit 2 ;;
  esac
done

log() { printf '%s\n' "==> $*"; }
warn() { printf '%s\n' "WARN: $*" >&2; }
die() { printf '%s\n' "ERROR: $*" >&2; exit 1; }

require_file() {
  [ -f "$1" ] || die "Required file missing: $SCRIPT_DIR/$1"
}

wait_until() {
  # usage: wait_until <timeout_seconds> <interval_seconds> <description> <command...>
  local timeout="$1" interval="$2" desc="$3"; shift 3
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if "$@"; then return 0; fi
    printf '    Waiting for %s... (%ss/%ss)\n' "$desc" "$elapsed" "$timeout"
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  return 1
}

install_prereqs() {
  log "Bootstrap: installing/checking host prerequisites"
  if ! command -v apt-get >/dev/null 2>&1; then
    die "--bootstrap currently supports Ubuntu/Debian hosts with apt-get."
  fi

  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg qemu-utils util-linux awscli tcpdump

  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker CE"
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<DOCKER_EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_EOF
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
    sudo usermod -aG docker "${SUDO_USER:-$USER}" || true
    warn "Docker group membership may require logout/login if docker is not usable without sudo."
  fi

  if ! command -v kind >/dev/null 2>&1; then
    log "Installing kind ${KIND_VERSION}"
    local arch
    arch="$(dpkg --print-architecture)"
    [ "$arch" = "amd64" ] || die "Automatic kind install currently expects amd64; found $arch"
    curl -fsSL -o /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    chmod +x /tmp/kind
    sudo mv /tmp/kind /usr/local/bin/kind
  fi
}

stop_port_forwards() {
  log "Stopping stale Ceph port-forward processes"
  pkill -f "kubectl -n ${NAMESPACE} port-forward .*${RGW_PORT}" 2>/dev/null || true
  pkill -f "kubectl -n ${NAMESPACE} port-forward .*${DASHBOARD_PORT}" 2>/dev/null || true
  sleep 1
}

disconnect_nbds() {
  log "Disconnecting NBD devices"
  sudo modprobe nbd max_part=8 2>/dev/null || true
  for i in 0 1 2; do
    if [ -e "/dev/nbd${i}" ]; then
      sudo qemu-nbd --disconnect "/dev/nbd${i}" 2>/dev/null || true
    fi
  done
  sleep 2
}

cleanup_ceph_lab() {
  log "Cleaning existing Ceph/kind lab state"
  stop_port_forwards

  if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    kind delete cluster --name "$CLUSTER_NAME" || true
  fi

  # Remove any orphaned kind containers if kind metadata is inconsistent.
  if command -v docker >/dev/null 2>&1; then
    docker ps -a --format '{{.Names}}' 2>/dev/null \
      | grep -E "^${CLUSTER_NAME}-(control-plane|worker|worker2|worker3)$" \
      | xargs -r docker rm -f >/dev/null 2>&1 || true
  fi

  disconnect_nbds

  log "Removing old NBD backing images from ${DISK_DIR}"
  sudo rm -rf "$DISK_DIR"

  # Remove only this cluster context, not the user's entire ~/.kube directory.
  if command -v kubectl >/dev/null 2>&1; then
    kubectl config delete-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 || true
    kubectl config delete-cluster "kind-${CLUSTER_NAME}" >/dev/null 2>&1 || true
    kubectl config delete-user "kind-${CLUSTER_NAME}" >/dev/null 2>&1 || true
  fi

  # kind normally removes its network itself; remove only if unused.
  if command -v docker >/dev/null 2>&1; then
    docker network rm kind >/dev/null 2>&1 || true
  fi

  log "Ceph lab cleanup completed"
}

cluster_is_healthy() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" || return 1
  kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 || return 1

  local health osd_up osd_in
  health="$(kubectl -n "$NAMESPACE" get cephcluster "$CLUSTER_NAME" -o jsonpath='{.status.ceph.health}' 2>/dev/null || true)"
  [ "$health" = "HEALTH_OK" ] || return 1

  if kubectl -n "$NAMESPACE" get deploy rook-ceph-tools >/dev/null 2>&1; then
    osd_up="$(kubectl -n "$NAMESPACE" exec deploy/rook-ceph-tools -- ceph osd stat -f json 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("num_up_osds",0))' 2>/dev/null || echo 0)"
    osd_in="$(kubectl -n "$NAMESPACE" exec deploy/rook-ceph-tools -- ceph osd stat -f json 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("num_in_osds",0))' 2>/dev/null || echo 0)"
    [ "$osd_up" -ge "$EXPECTED_OSDS" ] && [ "$osd_in" -ge "$EXPECTED_OSDS" ] || return 1
  fi
  return 0
}

if $BOOTSTRAP; then
  install_prereqs
fi

for f in kind-config.yaml operator-values.yaml cluster-values.yaml dashboard-loadbalancer.yaml object-store-user.yaml; do
  require_file "$f"
done

log "[0/10] Sanity checks"
for cmd in kind helm kubectl docker qemu-nbd wipefs base64 curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found. Install it or rerun with --bootstrap where supported."
done
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable by user $USER"
sudo modprobe nbd max_part=8

if [ "$MODE" = "cleanup" ]; then
  cleanup_ceph_lab
  exit 0
fi

if [ "$MODE" = "reinstall" ]; then
  warn "REINSTALL MODE: existing Ceph data in ${DISK_DIR} will be deleted."
  cleanup_ceph_lab
elif kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  if cluster_is_healthy; then
    log "Existing cluster is HEALTH_OK; preserving OSD data and continuing non-destructively."
  else
    cat >&2 <<MSG
ERROR: Existing kind cluster '${CLUSTER_NAME}' is present but is not confirmed healthy.
This protects your OSD data from accidental wipe.
If the cluster has detached OSDs, UNKNOWN state, or you intentionally want a fresh rebuild, run:
    bash $0 --reinstall
MSG
    exit 3
  fi
fi

log "[1/10] Preparing NBD backing images"
sudo mkdir -p "$DISK_DIR"
for node in worker-1 worker-2 worker-3; do
  file="$DISK_DIR/${node}.img"
  if [ ! -f "$file" ]; then
    echo "    Creating $file ($DISK_SIZE sparse)"
    sudo truncate -s "$DISK_SIZE" "$file"
  else
    echo "    Preserving existing $file"
  fi
done

log "[2/10] Starting kind cluster '${CLUSTER_NAME}'"
FRESH_CLUSTER=false
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "    Cluster already exists; skipping creation."
else
  kind create cluster --name "$CLUSTER_NAME" --config kind-config.yaml \
    || die "Failed to create kind cluster '${CLUSTER_NAME}'"
  FRESH_CLUSTER=true
fi
kind export kubeconfig --name "$CLUSTER_NAME" || die "Failed to export kubeconfig"
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

log "Waiting for all kind nodes to become Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=300s \
  || { kubectl get nodes -o wide; die "Not all kind nodes became Ready"; }

log "[3/10] Connecting NBD devices"
disconnect_nbds
sudo qemu-nbd --connect=/dev/nbd0 --format=raw "$DISK_DIR/worker-1.img"
sudo qemu-nbd --connect=/dev/nbd1 --format=raw "$DISK_DIR/worker-2.img"
sudo qemu-nbd --connect=/dev/nbd2 --format=raw "$DISK_DIR/worker-3.img"
sleep 3

for i in 0 1 2; do
  size="$(cat "/sys/block/nbd${i}/size" 2>/dev/null || echo 0)"
  [ "$size" -gt 0 ] || die "/dev/nbd${i} is not connected or has zero size"
done

# Only wipe disks for a truly fresh/reinstalled cluster. Never wipe a resumed healthy cluster.
if $FRESH_CLUSTER; then
  log "Fresh cluster: wiping stale filesystem/BlueStore signatures"
  for i in 0 1 2; do
    sudo wipefs -a "/dev/nbd${i}" || true
    sudo dd if=/dev/zero of="/dev/nbd${i}" bs=1M count=200 status=none
  done
fi

declare -A NODE_DEV=([worker-1]=0 [worker-2]=1 [worker-3]=2)
declare -A NODE_CTR=([worker-1]="${CLUSTER_NAME}-worker" [worker-2]="${CLUSTER_NAME}-worker2" [worker-3]="${CLUSTER_NAME}-worker3")
for node in worker-1 worker-2 worker-3; do
  ctr="${NODE_CTR[$node]}"
  own="${NODE_DEV[$node]}"
  docker inspect "$ctr" >/dev/null 2>&1 || die "kind container missing: $ctr"
  maj="$(printf '%d' "0x$(stat -c '%t' "/dev/nbd${own}")")"
  min="$(printf '%d' "0x$(stat -c '%T' "/dev/nbd${own}")")"
  docker exec --privileged "$ctr" rm -f "/dev/nbd${own}" 2>/dev/null || true
  docker exec --privileged "$ctr" mknod -m 0660 "/dev/nbd${own}" b "$maj" "$min"
  for other in $(seq 0 15); do
    [ "$other" -eq "$own" ] && continue
    docker exec --privileged "$ctr" rm -f "/dev/nbd${other}" 2>/dev/null || true
  done
  echo "    $node -> /dev/nbd${own}"
done

log "[4/10] Installing/upgrading Rook operator"
helm repo add rook-release https://charts.rook.io/release >/dev/null 2>&1 || true
helm repo update rook-release
kubectl create namespace "$NAMESPACE" >/dev/null 2>&1 || true
if helm status rook-ceph -n "$NAMESPACE" >/dev/null 2>&1; then
  helm upgrade rook-ceph rook-release/rook-ceph -n "$NAMESPACE" -f operator-values.yaml
else
  helm install rook-ceph rook-release/rook-ceph -n "$NAMESPACE" -f operator-values.yaml
fi
kubectl -n "$NAMESPACE" rollout status deploy/rook-ceph-operator --timeout=540s \
  || { kubectl -n "$NAMESPACE" get pods -o wide; die "Rook operator rollout failed"; }

log "[5/10] Installing/upgrading Ceph cluster"
if helm status rook-ceph-cluster -n "$NAMESPACE" >/dev/null 2>&1; then
  helm upgrade rook-ceph-cluster rook-release/rook-ceph-cluster -n "$NAMESPACE" -f cluster-values.yaml
else
  helm install rook-ceph-cluster rook-release/rook-ceph-cluster -n "$NAMESPACE" -f cluster-values.yaml
fi

log "Waiting for MON pods"
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod -l app=rook-ceph-mon --timeout=600s \
  || { kubectl -n "$NAMESPACE" get pods -o wide; die "MON pods did not become Ready"; }

log "Waiting for OSD prepare jobs to appear"
wait_until 300 10 "${EXPECTED_OSDS} OSD prepare jobs" bash -c \
  "[ \"\$(kubectl -n '$NAMESPACE' get jobs -l app=rook-ceph-osd-prepare --no-headers 2>/dev/null | wc -l)\" -ge '$EXPECTED_OSDS' ]" \
  || { kubectl -n "$NAMESPACE" get jobs; die "Expected OSD prepare jobs did not appear"; }

log "Waiting for OSD prepare jobs to complete"
wait_until 600 10 "${EXPECTED_OSDS} completed OSD prepare jobs" bash -c \
  "[ \"\$(kubectl -n '$NAMESPACE' get jobs -l app=rook-ceph-osd-prepare -o jsonpath='{range .items[*]}{.status.succeeded}{\"\\n\"}{end}' 2>/dev/null | grep -c '^1$' || true)\" -ge '$EXPECTED_OSDS' ]" \
  || { kubectl -n "$NAMESPACE" get jobs -l app=rook-ceph-osd-prepare; die "OSD prepare jobs did not complete"; }

log "Waiting for ${EXPECTED_OSDS} OSD pods to be Ready"
wait_until 600 10 "${EXPECTED_OSDS} ready OSD pods" bash -c \
  "[ \"\$(kubectl -n '$NAMESPACE' get pods -l app=rook-ceph-osd --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -c '2/2' || true)\" -ge '$EXPECTED_OSDS' ]" \
  || { kubectl -n "$NAMESPACE" get pods -l app=rook-ceph-osd -o wide; die "OSDs did not become Ready"; }

log "[6/10] Deploying toolbox and validating CRUSH/OSDs"
kubectl apply -f "$ROOK_TOOLBOX_URL"
kubectl -n "$NAMESPACE" rollout status deploy/rook-ceph-tools --timeout=300s \
  || die "Ceph toolbox did not become Ready"

# Keep the lab-specific CRUSH correction from the original workflow, but only run if needed.
worker2_exists="$(kubectl -n "$NAMESPACE" exec deploy/rook-ceph-tools -- ceph osd tree 2>/dev/null | grep -c "${CLUSTER_NAME}-worker2" || true)"
if [ "$worker2_exists" -eq 0 ]; then
  warn "CRUSH host buckets are incomplete; applying lab-specific OSD host spread."
  kubectl -n "$NAMESPACE" exec deploy/rook-ceph-tools -- bash -c "
    ceph osd crush add-bucket ${CLUSTER_NAME}-worker2 host 2>/dev/null || true
    ceph osd crush add-bucket ${CLUSTER_NAME}-worker3 host 2>/dev/null || true
    ceph osd crush move ${CLUSTER_NAME}-worker2 root=default 2>/dev/null || true
    ceph osd crush move ${CLUSTER_NAME}-worker3 root=default 2>/dev/null || true
    OSDS=\$(ceph osd tree --format json | python3 -c 'import json,sys; t=json.load(sys.stdin); print(\" \".join(str(n[\"id\"]) for n in t[\"nodes\"] if n.get(\"type\")==\"osd\" and n[\"id\"]!=0))')
    i=2
    for osd in \$OSDS; do
      ceph osd crush move osd.\${osd} host=${CLUSTER_NAME}-worker\${i} 2>/dev/null || true
      i=\$((i+1))
    done
  "
fi

kubectl -n "$NAMESPACE" exec deploy/rook-ceph-tools -- bash -c '
  for pool in $(ceph osd pool ls); do
    ceph osd pool set "$pool" min_size 1 2>/dev/null || true
  done
  for entity in client.csi-cephfs-node.1 client.csi-cephfs-provisioner.1 client.csi-rbd-node.1 client.csi-rbd-provisioner.1; do
    ceph auth del "$entity" 2>/dev/null || true
  done
  ceph config set mon auth_allow_insecure_global_id_reclaim false
  ceph config set mon mon_auth_allow_insecure_key false
'

log "[7/10] Applying dashboard service and waiting for HEALTH_OK"
kubectl apply -f dashboard-loadbalancer.yaml
health="unknown"
for _ in $(seq 1 60); do
  health="$(kubectl -n "$NAMESPACE" get cephcluster "$CLUSTER_NAME" -o jsonpath='{.status.ceph.health}' 2>/dev/null || echo unknown)"
  echo "    Health: $health"
  [ "$health" = "HEALTH_OK" ] && break
  sleep 10
done
if [ "$health" != "HEALTH_OK" ]; then
  kubectl -n "$NAMESPACE" exec deploy/rook-ceph-tools -- ceph -s || true
  die "Ceph did not reach HEALTH_OK"
fi

osd_stat="$(kubectl -n "$NAMESPACE" exec deploy/rook-ceph-tools -- ceph osd stat)"
echo "    $osd_stat"

log "[8/10] Waiting for RGW/ObjectStore and creating S3 user"
wait_until 600 10 "RGW service" kubectl -n "$NAMESPACE" get svc rook-ceph-rgw-rgw-store >/dev/null \
  || die "RGW service was not created"
kubectl apply -f object-store-user.yaml
SECRET_NAME="rook-ceph-object-user-rgw-store-s3-user"
ACCESS_KEY=""
SECRET_KEY=""
for _ in $(seq 1 60); do
  if kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; then
    ACCESS_KEY="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.AccessKey}' | base64 -d 2>/dev/null || true)"
    SECRET_KEY="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.SecretKey}' | base64 -d 2>/dev/null || true)"
    [ -n "$ACCESS_KEY" ] && [ -n "$SECRET_KEY" ] && break
  fi
  sleep 2
done
[ -n "$ACCESS_KEY" ] && [ -n "$SECRET_KEY" ] || die "S3 credentials were not created"

cat > .env <<ENV_EOF
CEPH_RGW_HOST=localhost
RGW_ACCESS_KEY=${ACCESS_KEY}
RGW_SECRET_KEY=${SECRET_KEY}
RGW_REGION=us-east-1
RGW_PORT=${RGW_PORT}
CEPH_BUCKET=${S3_BUCKET}
ENV_EOF
chmod 600 .env

log "[9/10] Starting RGW and dashboard port-forwards"
stop_port_forwards
nohup kubectl -n "$NAMESPACE" port-forward svc/rook-ceph-rgw-rgw-store "${RGW_PORT}:80" --address 0.0.0.0 \
  >"$LOG_DIR/rgw-port-forward.log" 2>&1 &
RGW_PID=$!

MGR_POD="$(kubectl -n "$NAMESPACE" get pod -l app=rook-ceph-mgr,mgr_role=active -o jsonpath='{.items[0].metadata.name}')"
[ -n "$MGR_POD" ] || die "Could not resolve active Ceph mgr pod"
nohup kubectl -n "$NAMESPACE" port-forward "pod/${MGR_POD}" "${DASHBOARD_PORT}:8443" --address 0.0.0.0 \
  >"$LOG_DIR/dashboard-port-forward.log" 2>&1 &
DASHBOARD_PID=$!

sleep 3
kill -0 "$RGW_PID" 2>/dev/null || { cat "$LOG_DIR/rgw-port-forward.log"; die "RGW port-forward failed"; }
kill -0 "$DASHBOARD_PID" 2>/dev/null || { cat "$LOG_DIR/dashboard-port-forward.log"; die "Dashboard pod port-forward failed"; }
curl -fsSI "http://127.0.0.1:${RGW_PORT}" >/dev/null || die "RGW endpoint did not answer on localhost:${RGW_PORT}"
curl -kfsSI "https://127.0.0.1:${DASHBOARD_PORT}/" >/dev/null || die "Dashboard did not answer on localhost:${DASHBOARD_PORT}"

log "[10/10] Creating/verifying S3 bucket '${S3_BUCKET}'"
if ! command -v aws >/dev/null 2>&1; then
  warn "aws CLI is not installed; skipping automatic bucket creation. Install with: sudo apt install -y awscli"
else
  export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
  export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
  export AWS_DEFAULT_REGION="us-east-1"
  if aws --endpoint-url "http://127.0.0.1:${RGW_PORT}" s3 ls "s3://${S3_BUCKET}" >/dev/null 2>&1; then
    echo "    Bucket ${S3_BUCKET} already exists."
  else
    aws --endpoint-url "http://127.0.0.1:${RGW_PORT}" s3 mb "s3://${S3_BUCKET}"
  fi
fi

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
DASH_PASS="$(kubectl -n "$NAMESPACE" get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' | base64 -d)"

echo
echo "======================================================"
echo " Ceph cluster is ready"
echo "======================================================"
echo "Ceph health:       ${health}"
echo "Dashboard URL:     https://${HOST_IP:-127.0.0.1}:${DASHBOARD_PORT}"
echo "Dashboard user:    admin"
echo "Dashboard password: ${DASH_PASS}"
echo "RGW S3 endpoint:   http://${HOST_IP:-127.0.0.1}:${RGW_PORT}"
echo "S3 bucket:         ${S3_BUCKET}"
echo "Environment file:  ${SCRIPT_DIR}/.env"
echo "Port-forward logs: ${LOG_DIR}/"
echo
echo "Admin checks:"
echo "  kubectl -n ${NAMESPACE} exec deploy/rook-ceph-tools -- ceph -s"
echo "  kubectl -n ${NAMESPACE} exec deploy/rook-ceph-tools -- ceph osd tree"
echo "  kubectl -n ${NAMESPACE} get pods -o wide"
echo "  aws --endpoint-url http://127.0.0.1:${RGW_PORT} s3 ls"
