#!/usr/bin/env bash
# Full Rook-Ceph RGW-only deployment on kind (docker driver).
# Run as normal user: bash deploy.sh (sudo is used only where root is needed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
if [ -n "${SUDO_USER:-}" ]; then
  export KUBECONFIG="/home/${SUDO_USER}/.kube/config"
fi

# ---------------------------------------------------------------------------
# 0. Sanity checks
# ---------------------------------------------------------------------------
echo "==> [0/8] Sanity checks..."
for cmd in kind helm kubectl docker qemu-nbd wipefs; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done

if ! lsmod | grep -q nbd && [ ! -e /dev/nbd0 ]; then
  sudo modprobe nbd max_part=8
fi

# ---------------------------------------------------------------------------
# 1. Create backing disk images (skipped if they already exist)
# ---------------------------------------------------------------------------
echo "==> [1/8] Preparing disk images..."
DIR="/var/lib/rook-loop-disks"
sudo mkdir -p "$DIR"
for NODE in worker-1 worker-2 worker-3; do
  FILE="$DIR/${NODE}.img"
  echo "    Creating $FILE (20G sparse)..."
  sudo rm -f "$FILE"
  sudo truncate -s 20G "$FILE"
done

# ---------------------------------------------------------------------------
# 2. Start kind cluster
# ---------------------------------------------------------------------------
echo "==> [2/8] Starting kind cluster 'rook-ceph'..."

if kind get clusters 2>/dev/null | grep -q "^rook-ceph$"; then
    echo "    kind cluster 'rook-ceph' already exists, skipping."
else
    echo "    Creating kind cluster 'rook-ceph'..."

    if ! kind create cluster --name rook-ceph --config kind-config.yaml; then
        echo "    ERROR: Failed to create kind cluster 'rook-ceph'."
        echo "    Continuing with the script..."
    else
        echo "    Kind cluster 'rook-ceph' created successfully."
    fi
fi

echo "==> Exporting kubeconfig..."
if ! kind export kubeconfig --name rook-ceph; then
    echo "    ERROR: Failed to export kubeconfig."
    echo "    Continuing with the script..."
fi

# Give node containers a moment to fully start
sleep 5
# ---------------------------------------------------------------------------
# 3. Connect NBD devices, wipe, inject into node containers
# ---------------------------------------------------------------------------
echo "==> [3/8] Connecting NBD devices..."

# Disconnect any stale connections first
for i in 0 1 2; do
  sudo qemu-nbd --disconnect /dev/nbd$i 2>/dev/null || true
done
sleep 2

# Connect each image to its NBD device
sudo qemu-nbd --connect=/dev/nbd0 --format=raw "$DIR/worker-1.img"
sudo qemu-nbd --connect=/dev/nbd1 --format=raw "$DIR/worker-2.img"
sudo qemu-nbd --connect=/dev/nbd2 --format=raw "$DIR/worker-3.img"
sleep 3

# Verify all devices are connected and non-zero
for i in 0 1 2; do
  size=$(cat /sys/block/nbd${i}/size 2>/dev/null || echo 0)
  [ "$size" -gt 0 ] || { echo "ERROR: /dev/nbd${i} not connected or zero size"; exit 1; }
done
echo "    nbd0/1/2 all connected."

# Wipe stale bluestore/filesystem metadata from previous runs
echo "    Wiping stale metadata from nbd devices..."
for i in 0 1 2; do
  sudo wipefs -a /dev/nbd${i}
  sudo dd if=/dev/zero of=/dev/nbd${i} bs=1M count=200 status=none
done
echo "    Wipe done."

# Inject correct device node into each container and remove all others (nbd0-15)
# kind container names: rook-ceph-worker, rook-ceph-worker2, rook-ceph-worker3
declare -A NODE_DEV=([worker-1]=0 [worker-2]=1 [worker-3]=2)
declare -A NODE_CTR=([worker-1]="rook-ceph-worker" [worker-2]="rook-ceph-worker2" [worker-3]="rook-ceph-worker3")
for NODE in worker-1 worker-2 worker-3; do
  CTR="${NODE_CTR[$NODE]}"
  OWN="${NODE_DEV[$NODE]}"

  MAJ=$(printf '%d' "0x$(stat -c '%t' /dev/nbd${OWN})")
  MIN=$(printf '%d' "0x$(stat -c '%T' /dev/nbd${OWN})")
  docker exec --privileged "$CTR" mknod -m 0660 /dev/nbd${OWN} b "$MAJ" "$MIN" 2>/dev/null || true

  for OTHER in $(seq 0 15); do
    [ "$OTHER" -eq "$OWN" ] && continue
    docker exec --privileged "$CTR" rm -f /dev/nbd${OTHER} 2>/dev/null || true
  done

  echo "    $NODE -> /dev/nbd${OWN} injected, nbd0-15 others removed."
done

# ---------------------------------------------------------------------------
# 4. Install Rook operator
# ---------------------------------------------------------------------------
echo "==> [4/8] Installing Rook operator..."
helm repo add rook-release https://charts.rook.io/release 2>/dev/null || true
helm repo update rook-release

kubectl create namespace rook-ceph 2>/dev/null || true

if helm status rook-ceph -n rook-ceph &>/dev/null; then
  echo "    Rook operator already installed, skipping."
else
  helm install rook-ceph rook-release/rook-ceph \
    --namespace rook-ceph \
    -f operator-values.yaml
fi

echo "    Waiting for operator rollout..."
kubectl -n rook-ceph rollout status deploy/rook-ceph-operator --timeout=540s

# ---------------------------------------------------------------------------
# 5. Install Ceph cluster
# ---------------------------------------------------------------------------
echo "==> [5/8] Installing Ceph cluster..."
if helm status rook-ceph-cluster -n rook-ceph &>/dev/null; then
  echo "    Ceph cluster already installed, skipping."
  # Delete completed/failed OSD prepare jobs so operator re-triggers them
  kubectl -n rook-ceph delete jobs -l app=rook-ceph-osd-prepare 2>/dev/null || true
else
  helm install rook-ceph-cluster rook-release/rook-ceph-cluster \
    --namespace rook-ceph \
    -f cluster-values.yaml
fi
sleep 600
echo "    Waiting for mons (up to 5 min)..."
kubectl -n rook-ceph wait --for=condition=ready pod -l app=rook-ceph-mon --timeout=300s

# Wait for OSD prepare jobs to appear (up to 3 min)
echo "    Waiting for OSD prepare jobs to start..."
for i in $(seq 1 18); do
  job_count=$(kubectl -n rook-ceph get jobs --no-headers 2>/dev/null | grep -c "osd-prepare" || true)
  [ "$job_count" -ge 3 ] && break
  echo "    OSD prepare jobs found: $job_count/3 — waiting..."
  sleep 180
done

# Wait for OSD prepare jobs to complete (up to 5 min)
echo "    Waiting for OSD prepare jobs to complete..."
for i in $(seq 1 30); do
  done_count=$(kubectl -n rook-ceph get jobs --no-headers 2>/dev/null | grep "osd-prepare" | grep -c "1/1" || true)
  [ "$done_count" -ge 3 ] && break
  echo "    OSD prepare jobs done: $done_count/3 — waiting..."
  sleep 180
done

# Wait for OSD pods to be Running (up to 5 min)
echo "    Waiting for OSD pods (up to 5 min)..."
osd_count=0
for i in $(seq 1 30); do
  osd_count=$(kubectl -n rook-ceph get pods -l app=rook-ceph-osd --no-headers 2>/dev/null | grep -c "Running" || true)
  [ "$osd_count" -ge 3 ] && break
  echo "    OSDs running: $osd_count/3 — waiting..."
  sleep 180
done
[ "$osd_count" -ge 3 ] || { echo "ERROR: OSDs did not come up in time"; exit 1; }

# ---------------------------------------------------------------------------
# 6. Fix CRUSH map + toolbox
# ---------------------------------------------------------------------------
echo "==> [6/8] Fixing CRUSH map..."
kubectl apply -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/toolbox.yaml
kubectl -n rook-ceph rollout status deploy/rook-ceph-tools --timeout=180s

worker2_exists=$(kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd tree 2>/dev/null | grep -c "rook-ceph-worker2" || true)

if [ "$worker2_exists" -eq 0 ]; then
  echo "    Spreading OSDs across host buckets..."
  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- bash -c '
    ceph osd crush add-bucket rook-ceph-worker2 host
    ceph osd crush add-bucket rook-ceph-worker3 host
    ceph osd crush move rook-ceph-worker2 root=default
    ceph osd crush move rook-ceph-worker3 root=default
    OSDS=$(ceph osd tree --format json | python3 -c "
import json,sys
t=json.load(sys.stdin)
ids=[str(n[\"id\"]) for n in t[\"nodes\"] if n.get(\"type\")==\"osd\" and n[\"id\"]!=0]
print(\" \".join(ids))
")
    i=2
    for osd in $OSDS; do
      ceph osd crush move osd.${osd} host=rook-ceph-worker${i}
      i=$((i+1))
    done
  '
else
  echo "    CRUSH map already correct, skipping."
fi

# Set min_size 1 on all pools so they stay active with 3 OSDs at replication size 2
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- bash -c '
  for pool in $(ceph osd pool ls); do
  # ceph osd pool set $pool size 1 --yes-i-really-mean-it 2>/dev/null || true
    ceph osd pool set $pool min_size 1 2>/dev/null || true
  done
  # Remove stale CSI auth entities with insecure key types (created by disabled CSI drivers)
  for entity in client.csi-cephfs-node.1 client.csi-cephfs-provisioner.1 client.csi-rbd-node.1 client.csi-rbd-provisioner.1; do
    ceph auth del $entity 2>/dev/null || true
  done
  ceph config set mon auth_allow_insecure_global_id_reclaim false
  ceph config set mon mon_auth_allow_insecure_key false
  ceph health mute AUTH_INSECURE_KEYS_ALLOWED 2>/dev/null || true
  ceph health mute AUTH_INSECURE_KEYS_CREATABLE 2>/dev/null || true
  ceph health mute AUTH_INSECURE_CLIENT_KEY_TYPE 2>/dev/null || true
'

# ---------------------------------------------------------------------------
# 7. Apply NodePort service + wait
# ---------------------------------------------------------------------------
echo "==> [7/8] Applying dashboard NodePort service..."
kubectl apply -f dashboard-loadbalancer.yaml

NODE_IP=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "127.0.0.1")

# ---------------------------------------------------------------------------
# 7b. Wait for HEALTH_OK
# ---------------------------------------------------------------------------
echo "==> [7/8] Waiting for HEALTH_OK (up to 5 min)..."
health="unknown"
for i in $(seq 1 30); do
  health=$(kubectl -n rook-ceph get cephcluster rook-ceph \
    -o jsonpath='{.status.ceph.health}' 2>/dev/null || echo "unknown")
  echo "    Health: $health"
  [ "$health" = "HEALTH_OK" ] && break
  sleep 10
done
# ---------------------------------------------------------------------------
# 8. Write .env for app.py
# ---------------------------------------------------------------------------
echo "==> Writing .env..."

kubectl apply -f object-store-user.yaml

echo "    Waiting for S3 credentials..."

SECRET_NAME="rook-ceph-object-user-rgw-store-s3-user"

for i in {1..30}; do
    if kubectl -n rook-ceph get secret "$SECRET_NAME" >/dev/null 2>&1; then
        ACCESS_KEY=$(kubectl -n rook-ceph get secret "$SECRET_NAME" \
            -o jsonpath='{.data.AccessKey}' 2>/dev/null | base64 -d)

        SECRET_KEY=$(kubectl -n rook-ceph get secret "$SECRET_NAME" \
            -o jsonpath='{.data.SecretKey}' 2>/dev/null | base64 -d)

        if [ -n "$ACCESS_KEY" ] && [ -n "$SECRET_KEY" ]; then
            break
        fi
    fi

    echo "    Waiting for S3 credentials... ($i/30)"
    sleep 2
done

if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
    echo "ERROR: S3 credentials were not created."
    exit 1
fi

cat > .env <<EOF
CEPH_RGW_HOST=localhost
RGW_ACCESS_KEY=${ACCESS_KEY}
RGW_SECRET_KEY=${SECRET_KEY}
RGW_REGION=us-east-1
RGW_PORT=7480
CEPH_BUCKET=test
EOF

echo "    .env written."
echo "Run rgw endpoint"
kubectl -n rook-ceph port-forward svc/rook-ceph-rgw-rgw-store 7480:80 --address 0.0.0.0 >/dev/null 2>&1 &
RGW_PID=$!

kubectl -n rook-ceph port-forward svc/rook-ceph-mgr-dashboard 7000:7000 --address 0.0.0.0 >/dev/null 2>&1 &
DASHBOARD_PID=$!

sleep 2
for i in {1..10}; do

    RGW_OK=false
    DASHBOARD_OK=false

    if kill -0 "$RGW_PID" 2>/dev/null; then
        RGW_OK=true
    fi

    if kill -0 "$DASHBOARD_PID" 2>/dev/null; then
        DASHBOARD_OK=true
    fi

    if $RGW_OK && $DASHBOARD_OK; then
        break
    fi

    echo "Waiting for port-forwards... ($i/10)"
    sleep 2
done

if $RGW_OK; then
    echo "RGW port-forward (7480): RUNNING"
else
    echo "RGW port-forward (7480): FAILED"
fi

if $DASHBOARD_OK; then
    echo "Dashboard port-forward (7000): RUNNING"
else
    echo "Dashboard port-forward (7000): FAILED"
fi
# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "======================================================"
echo " Ceph cluster is up!"
echo "======================================================"
echo ""
echo "Dashboard: https://${NODE_IP}:30700  (user: admin)"
echo "Password:"
kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
  -o jsonpath="{['data']['password']}" | base64 -d; echo
echo ""
echo "RGW S3 endpoint: http://localhost:7480  (via port-forward)"
echo "  Run: kubectl -n rook-ceph port-forward svc/rook-ceph-rgw-rgw-store 7480:80"
echo ""
echo "Create S3 user:  kubectl apply -f object-store-user.yaml"
