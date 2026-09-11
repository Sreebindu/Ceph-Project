# Ceph / Rook / kind Administrator Command Notes

## Script modes

```bash
# Normal non-destructive deploy/resume
bash deploy_fixed.sh

# Install missing host prerequisites, then deploy
bash deploy_fixed.sh --bootstrap

# Fresh rebuild for detached/UNKNOWN/broken lab OSD state
bash deploy_fixed.sh --reinstall

# Remove Ceph/kind/NBD lab state and exit
bash deploy_fixed.sh --cleanup-only
```

> `--reinstall` and `--cleanup-only` delete `/var/lib/rook-loop-disks` and therefore delete the lab Ceph data.

## Cluster and health

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph health detail
kubectl -n rook-ceph get cephcluster -o wide
kubectl -n rook-ceph get pods -o wide
kubectl -n rook-ceph get events --sort-by=.lastTimestamp | tail -50
```

## OSD administration

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd stat
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd df tree
kubectl -n rook-ceph get jobs -l app=rook-ceph-osd-prepare
kubectl -n rook-ceph get pods -l app=rook-ceph-osd -o wide
```

## MON / MGR / services

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph mon stat
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph mgr stat
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph mgr services
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph mgr module ls | grep dashboard
```

## Pools / placement groups / capacity

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool ls detail
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph pg stat
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph df
```

## RGW / S3

```bash
kubectl -n rook-ceph get cephobjectstore -o wide
kubectl -n rook-ceph get cephobjectstoreuser
kubectl -n rook-ceph get pods -l app=rook-ceph-rgw -o wide
kubectl -n rook-ceph get svc rook-ceph-rgw-rgw-store
curl -I http://127.0.0.1:7480

kubectl -n rook-ceph exec deploy/rook-ceph-tools -- radosgw-admin bucket list
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- radosgw-admin user info --uid=s3-user

aws --endpoint-url http://127.0.0.1:7480 s3 ls
aws --endpoint-url http://127.0.0.1:7480 s3 ls s3://pcaps/
aws --endpoint-url http://127.0.0.1:7480 s3 cp ~/test.pcap s3://pcaps/test.pcap
```

## S3 credentials

```bash
ACCESS_KEY=$(kubectl -n rook-ceph get secret \
  rook-ceph-object-user-rgw-store-s3-user \
  -o jsonpath='{.data.AccessKey}' | base64 -d)

SECRET_KEY=$(kubectl -n rook-ceph get secret \
  rook-ceph-object-user-rgw-store-s3-user \
  -o jsonpath='{.data.SecretKey}' | base64 -d)

export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
export AWS_DEFAULT_REGION=us-east-1
```

## Dashboard

```bash
# Password
kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
  -o jsonpath='{.data.password}' | base64 -d; echo

# Direct active-mgr pod forward (tested working)
MGR=$(kubectl -n rook-ceph get pod \
  -l app=rook-ceph-mgr,mgr_role=active \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n rook-ceph port-forward pod/$MGR 7000:8443 --address 0.0.0.0

# Verify locally
curl -kI https://127.0.0.1:7000/
```

Dashboard URL from another machine on the same network:

```text
https://<CEPH_VM_IP>:7000
```

Username: `admin`

## Rook and daemon logs

```bash
kubectl -n rook-ceph logs deploy/rook-ceph-operator --tail=200
kubectl -n rook-ceph logs -l app=rook-ceph-mgr --all-containers=true --tail=200
kubectl -n rook-ceph logs -l app=rook-ceph-osd --all-containers=true --tail=200
kubectl -n rook-ceph describe cephcluster rook-ceph
```

## kind / Docker

```bash
kind get clusters
kubectl get nodes -o wide
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker system df
```

## NBD checks

```bash
lsblk
ls -l /dev/nbd0 /dev/nbd1 /dev/nbd2
lsmod | grep nbd

for i in 0 1 2; do
  echo -n "nbd$i sectors: "
  cat /sys/block/nbd$i/size
done

sudo fuser -v /dev/nbd* 2>/dev/null
```

## Manual targeted cleanup

```bash
# Stop Ceph forwards
pkill -f 'kubectl -n rook-ceph port-forward' 2>/dev/null || true

# Delete the kind cluster
kind delete cluster --name rook-ceph

# Disconnect NBDs
for i in 0 1 2; do
  sudo qemu-nbd --disconnect /dev/nbd$i 2>/dev/null || true
done

# Delete Ceph backing images (DESTRUCTIVE)
sudo rm -rf /var/lib/rook-loop-disks
```

## Deep host cleanup (only for a dedicated lab VM)

```bash
docker system prune -a --volumes -f
sudo systemctl stop docker docker.socket 2>/dev/null || true
sudo systemctl stop containerd 2>/dev/null || true
sudo apt purge -y docker-ce docker-ce-cli docker-ce-rootless-extras \
  docker-buildx-plugin docker-compose-plugin containerd.io
sudo apt autoremove -y
sudo apt autoclean
sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker
```

Do **not** use deep host cleanup on a shared Docker VM unless deleting unrelated Docker resources is acceptable.
