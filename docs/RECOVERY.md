# Recovery and rollback: lab only

## When the SSH tunnel stops

A persistent `tun7` interface can show `UP` or retain its IP address even without an attached SSH process. Always verify real bidirectional **ping**. From the Mac:

```bash
./scripts/05-start-tunnel.sh status
./scripts/05-start-tunnel.sh start
./scripts/06-complete-fabric.sh bgp-check
```

If `start` reports an existing stale SSH process, inspect the actual `ssh -w 7:7` process on Bastion A before stopping/restarting it. Do not run multiple conflicting tunnel instances.

## After node and bastion reboots

1. Verify the bastions' `sshd` settings and local SSH public-key trust; verify `sudo -n true`.
2. Restore tunnel and TUN addresses: `./scripts/05-start-tunnel.sh start`.
3. Restore bastion static VTEP routes and narrow nftables `FORWARD` rules **without restarting FRR**: `./scripts/06-complete-fabric.sh restore-underlay`.
4. Restore both clusters' nonpersistent host routes via `./scripts/07-restore-node-routes.sh` (it also runs `restore-underlay`; repeating the route restores is safe).
5. Run `./scripts/04-test.sh --full` and guest-to-guest ping. Check FRR service state if BGP sessions aren't reestablished.

The 14 dummy VTEP `/32` interface addresses are managed by Kubernetes NMState NNCPs and should reconcile automatically. The host `ip route` changes, bastion nftables runtime inserts and background SSH process are **not durable**. Don't assume a reboot preserves them.

## Backups and reverting an incomplete switch

The original v4 switch saved cluster backups before changing anything (for the successful workshop run, under the user's home directory as `ocp422-evpn-backup-<timestamp>`). Each future switch run creates another backup outside Git containing NNCPs, VTEP CRs and the source `FRRConfiguration` objects for both clusters. Bastion `fabric` runs also write timestamped copies of `/etc/frr/frr.conf` and `/etc/frr/daemons`.

**Do not blindly `oc apply` backups with server-managed status/resourceVersion metadata.** Plan a coordinated rollback: stop guest traffic; identify the exact backup matching the migration; restore FRR peers and VTEPs/NNCP addresses for both sites consistently; verify the old routes are reachable; and restore bastion FRR config from its corresponding timestamped backup if necessary. The previous `172.31.250.0/24` range overlaps the OCP `172.31.0.0/16` service CIDR and is **not** an acceptable steady-state rollback target. Prefer fixing or restoring the nonoverlapping `10.251.10/24` and `10.251.20/24` network.

The proven production of type-3 EVPN routes does not itself verify guest MAC reachability; perform the final guest ping and inspect guest ARP and FRR type-2 prefixes.
