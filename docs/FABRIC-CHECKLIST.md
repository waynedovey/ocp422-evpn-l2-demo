# Fabric checklist: working two-bastion lab

- [x] Both workshop bastions can reach all of their **local** OpenShift nodes on their respective `10.10.10.0/24` network.
- [x] Site A can authenticate to Site B over the published SSH gateway. The reverse public TCP path is not required.
- [x] OpenSSH point-to-point `tun7`: `10.254.254.1 ↔ 10.254.254.2`, bidirectional ping proved.
- [x] FRR 8.5.3 installed on both RHEL 9 bastions. Its EVPN configuration passed `vtysh -C` on both hosts.
- [x] Bastion AS65000 ↔ AS65000 iBGP EVPN established over `tun7`.
- [x] Seven site A peers (AS65001) and seven site B peers (AS65002) established to local `10.10.10.1`.
- [x] Site A VTEPs `10.251.10.11–17`; Site B `10.251.20.21–27`, all NNCPs `Available` and VTEP CRs `Accepted`.
- [x] Bastion routes for every local VTEP `/32` and remote VTEP `/24` installed; forwarding rules allow just the two site VTEP prefixes.
- [x] Worker VTEPs `10.251.10.15 ↔ 10.251.20.24` ping each other across the two bastions.
- [x] VNI `5050` / RT `65000:5050` shared; both bastions had 14 type-3 EVPN prefixes and both VM hosts discovered 13 other VTEPs.
- [x] Real guest ping `10.250.50.3 → 10.250.50.4`, 4/4 replies; remote MAC `0a:58:0a:fa:32:04` appeared `REACHABLE` in the guest neighbor table.

## Required outside this lab

- Durable redundant L3 underlay/VPN (rather than a user-started SSH tunnel); approved security policy.
- Properly sized transit MTU for VXLAN overhead and non-overlapping VTEP routing; test real application traffic, not only ICMP.
- Persisted worker remote-VTEP routes and bastion forwarding rules; redundant BGP peers and failure detection.
- No globally weakened SSH, SELinux or firewall controls. Restrict any `PermitTunnel` allowance to intended lab users and hosts.
- Document recovery and rollback; use site-specific IP allocation to avoid DHCP collisions across stretched L2 networks.

See [OpenShift 4.22 EVPN documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/advanced_networking/bgp-evpn-for-user-defined-networks) and [Operations](OPERATIONS.md).
