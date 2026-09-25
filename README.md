# OpenShift 4.22 — Cross-Cluster Layer 2 EVPN

Two OpenShift 4.22 clusters share a Layer 2 user-defined network across sites. Each cluster peers with its local RHEL 9/FRR bastion using BGP EVPN. An encrypted SSH TUN link connects the bastions and carries the routed VXLAN traffic.

This lab was verified with a successful **VM-to-VM ping across both clusters**.

## Topology

![Two-site OpenShift EVPN topology](docs/topology.svg)

## Lab configuration

| | Site A (kcp74) | Site B (9r9gz) |
|---|---|---|
| OpenShift nodes | 3 control plane + 4 workers | 3 control plane + 4 workers |
| Cluster ASN | 65001 | 65002 |
| Bastion ASN | 65000 | 65000 |
| Bastion SSH access | `ssh.ocpv02.rhdp.net:31482` | `ssh.ocpv08.rhdp.net:31156` |
| Bastion local IP | `10.10.10.1` | `10.10.10.1` |
| Tunnel IP | `10.254.254.1` | `10.254.254.2` |
| VTEP subnet | `10.251.10.0/24` | `10.251.20.0/24` |
| VM-host VTEP | `10.251.10.15` | `10.251.20.24` |
| Demo VM | `vm-site-a` · `10.250.50.3` | `vm-site-b` · `10.250.50.4` |

**Shared network:** `sydney-l2-evpn` · VNI `5050` · route target `65000:5050` · subnet `10.250.50.0/24`.

## Requirements

- Two bare-metal OpenShift 4.22 clusters with OVN-Kubernetes, OpenShift Virtualization, Kubernetes NMState, the FRR routing provider and route advertisements.
- Cluster-admin access to both clusters; SSH access to both RHEL 9 bastions with permission to configure FRR, SSH tunnelling, routes and nftables.
- A Mac or Linux workstation with `git`, `oc`, `virtctl`, `jq`, `bash`, `python3`, `ssh` and `scp`.
- Separate, routable VTEP subnets at both sites. Do **not** route the overlapping `10.10.10.0/24` management networks between sites.

## Deployment steps

These steps are for a **new or rebuilt copy of this workshop lab**. If the existing two-site lab is already working, **skip deployment and use [Validation](#validation)**; re-running the `switch` stage can interrupt live EVPN networking.

**1. Clone the repository and connect to both clusters.**

```bash
git clone https://github.com/waynedovey/ocp422-evpn-l2-demo.git
cd ocp422-evpn-l2-demo

./scripts/00-login.sh
source ./.site-contexts.env
./scripts/00-preflight.sh
```

Verify that both contexts point to **different** API servers and that all required CRDs are present. If FRR, route advertisements, `routingViaHost` or global IP forwarding are missing, enable them on both clusters and check network operator health before continuing:

```bash
./scripts/01-enable-cluster-networking.sh site-a
./scripts/01-enable-cluster-networking.sh site-b
./scripts/00-preflight.sh
```

**2. Prepare the bastions.**

Install FRR 8.5 on **both** RHEL 9 bastions:

```bash
sudo dnf install -y frr
```

On **Bastion B**, enable point-to-point SSH tunnelling (only with approval for this workshop host):

```bash
printf 'PermitTunnel point-to-point\n' | sudo tee /etc/ssh/sshd_config.d/04-evpn-lab.conf
sudo /usr/sbin/sshd -t
sudo systemctl reload sshd
```

On **Bastion A**, ensure `lab-user` has an SSH identity and authorise **only its public key** on Bastion B. Verify Bastion B's host key fingerprint before accepting it:

```bash
test -r ~/.ssh/id_rsa.pub || ssh-keygen -t rsa -b 3072 -f ~/.ssh/id_rsa
ssh-copy-id -i ~/.ssh/id_rsa.pub -p 31156 lab-user@ssh.ocpv08.rhdp.net
ssh -F /dev/null -i ~/.ssh/id_rsa -o IdentitiesOnly=yes -o BatchMode=yes \
  -p 31156 lab-user@ssh.ocpv08.rhdp.net true
```

See [Operations](docs/OPERATIONS.md) for the bastion prerequisites, required `sudo -n` access and SSH troubleshooting.

**3. Establish the encrypted inter-site tunnel.** From the cloned repository on your workstation:

```bash
./scripts/05-start-tunnel.sh start
./scripts/05-start-tunnel.sh status
```

Confirm that `tun7` can ping in **both directions** (`10.254.254.1 ↔ 10.254.254.2`).

**4. Create the VTEPs and cluster network resources.**

The site deployment scripts apply the namespace, all seven per-site NMState VTEP policies, the unmanaged VTEP resource, the local FRRConfiguration, RouteAdvertisements and the Layer 2 CUDN. Network-only mode does not create VMs.

```bash
./scripts/02-deploy-site-a.sh --network-only
./scripts/03-deploy-site-b.sh --network-only
```

Wait for the 14 NNCPs to become `Available` and each `sydney-vtep` to become `Accepted`. The scripts check these conditions.

**5. Configure and verify the bastion EVPN fabric.**

```bash
./scripts/06-complete-fabric.sh frr-check
./scripts/06-complete-fabric.sh fabric
./scripts/06-complete-fabric.sh bgp-check
```

The `fabric` stage configures the bastions' FRR daemons, VTEP routes and narrowly scoped nftables forwarding rules. Do not continue unless **both inter-bastion EVPN sessions are established**. FRR displays a numeric received-prefix count (including `0`) for an established session.

**6. Complete the cross-site VTEP routing.**

```bash
./scripts/06-complete-fabric.sh switch
```

This stage backs up existing cluster networking resources, installs temporary remote-VTEP routes on all 14 OpenShift nodes and updates any old VTEPs/BGP peers. Review the output and type `SWITCH` to confirm. On a fresh deployment, the VTEP and peer manifests should already have the new addresses; the node routes are still required. **Do not run this stage again against a healthy live lab.**

**7. Create the demo VMs.**

Provide an existing SSH **public** key for new guests, then deploy the VMs. Existing VMs are not recreated.

```bash
export VM_SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_ed25519.pub"
./scripts/02-deploy-site-a.sh
./scripts/03-deploy-site-b.sh
```

Confirm both VMs are `Running` and have **different guest IP addresses**. The `.3` and `.4` addresses in the table were observed in the completed lab; fresh DHCP allocations may differ.

## Validation

Check BGP, remote EVPN routes, accepted CUDNs and VTEP connectivity:

```bash
./scripts/06-complete-fabric.sh verify
./scripts/04-test.sh --full
```

Open Site A's VM console and ping **Site B's actual guest IP** (shown here as the verified workshop address):

```bash
virtctl --context="$SITE_A_CONTEXT" -n evpn-demo console vm-site-a
# Inside the VM:
ping -c 4 10.250.50.4
ip neigh show 10.250.50.4
```

After generating guest traffic, check that each site learned the remote VM MAC:

```bash
./scripts/04-test.sh --strict
```

**Verified result:** `vm-site-a` (`10.250.50.3`) reached `vm-site-b` (`10.250.50.4`) with **4/4 replies**, and ARP resolved the remote MAC `0a:58:0a:fa:32:04`.

## Documentation and recovery

- [Operations](docs/OPERATIONS.md): bastion setup, FRR, routing and troubleshooting.
- [Fabric checklist](docs/FABRIC-CHECKLIST.md): prerequisite and acceptance checklist.
- [Recovery](docs/RECOVERY.md): restore the tunnel, temporary routes and firewall rules after reboots.
- [Site A](site-a/) · [Site B](site-b/) · [Fabric](fabric/) · [Scripts](scripts/): deployment resources.

> **Lab only:** The SSH tunnel, runtime node routes and nftables changes are not persistent or highly available. Use a properly designed routed underlay for production.
