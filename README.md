# Ceph-Project
The biggest reliability problem in the script was that it deleted/recreated the three backing images and wiped the NBD devices even on reruns, while also continuing after some failures. Terminal history also shows the successful fresh-rebuild cleanup sequence: delete the kind cluster, remove the loop-disk directory, clean Docker/kind state, verify the host, then rebuild.

Fixed deploy script — supports normal non-destructive deploy, --reinstall, --cleanup-only, and --bootstrap.
Ceph installation/uninstallation runbook — covers installation, targeted reinstall, full host cleanup, dashboard, RGW/S3, OSD troubleshooting, and operational checks.
Ceph admin command cheat sheet — quick commands for health, OSDs, MON/MGR, pools, RGW, dashboard, logs, kind, Docker, NBD, cleanup, and S3.

The revised script also includes the additional steps that were missing from your original workflow: host prerequisite/bootstrap handling, safer NBD cleanup, node readiness checks, proper bounded OSD waits, HEALTH_OK validation, working dashboard forwarding through the active mgr pod on 7000:8443, RGW validation on 7480, AWS CLI/S3 credential handling, and automatic creation/verification of the pcaps bucket. Your terminal history confirmed the final cluster reached HEALTH_OK with all three OSDs up and in.

For future use, the important commands are:

# Normal run — preserves healthy existing OSD data
bash deploy_fixed.sh

# Fresh rebuild after detached OSD / UNKNOWN / broken disposable cluster
bash deploy_fixed.sh --reinstall

# Remove Ceph/kind/NBD lab state only
bash deploy_fixed.sh --cleanup-only

# Install missing host prerequisites and deploy
bash deploy_fixed.sh --bootstrap

--reinstall and --cleanup-only are intentionally destructive to /var/lib/rook-loop-disks, so use them only when you want to discard the current Ceph data. The separate deep Docker/containerd purge you performed is documented in the runbook but is deliberately not part of normal Ceph reinstallation.

deploy_fixed.sh
Ceph_Rook_Kind_Installation_Uninstallation_Guide.docx
Ceph_Admin_Commands.md

