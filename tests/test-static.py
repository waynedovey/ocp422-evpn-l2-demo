#!/usr/bin/env python3
"""Offline structural tests for the published workshop topology (requires PyYAML)."""
from pathlib import Path
import re
import yaml
root = Path(__file__).resolve().parents[1]


def manifest(name):
    return yaml.safe_load((root / name).read_text())

all_vteps = set()
for site, prefix, asn, lo, hi in [('a', '10.251.10.', 65001, 11, 17), ('b', '10.251.20.', 65002, 21, 27)]:
    site_name = f'site-{site}'
    vtep = manifest(f'{site_name}/02-vtep.yaml')
    assert vtep['spec']['mode'] == 'Unmanaged'
    assert vtep['spec']['cidrs'] == [f'10.251.{10 if site == "a" else 20}.0/24']
    frr = manifest(f'{site_name}/01-frrconfiguration.yaml')
    assert frr['spec']['bgp']['routers'][0]['asn'] == asn
    assert frr['spec']['bgp']['routers'][0]['neighbors'][0]['address'] == '10.10.10.1'
    assert frr['spec']['bgp']['routers'][0]['neighbors'][0]['asn'] == 65000
    nncps = [manifest(str(p.relative_to(root))) for p in sorted((root / site_name / 'nncp').glob('*.yaml'))]
    assert len(nncps) == 7
    expected = {f'{prefix}{n}' for n in range(lo, hi + 1)}
    actual = {p['spec']['desiredState']['interfaces'][0]['ipv4']['address'][0]['ip'] for p in nncps}
    assert expected == actual and not (all_vteps & actual)
    all_vteps.update(actual)
    for p in nncps:
        name = p['spec']['nodeSelector']['kubernetes.io/hostname']
        assert p['metadata']['name'] == f'evpn-vtep-{name}'
        iface = p['spec']['desiredState']['interfaces'][0]
        assert iface['name'] == 'evpn-vtep0' and iface['type'] == 'dummy'
        assert iface['ipv4']['address'][0]['prefix-length'] == 32
    vm_src = (root / site_name / f'05-vm-site-{site}.yaml').read_text()
    assert '__SSH_PUBLIC_KEY__' in vm_src and 'redhat123' not in vm_src
    vm = yaml.safe_load(vm_src)
    assert vm['spec']['template']['spec']['domain']['devices']['interfaces'][0]['binding']['name'] == 'l2bridge'
    assert vm['spec']['template']['spec']['volumes'][1]['cloudInitNoCloud']['networkData'].find('enp1s0:') >= 0
    conf = (root / f'fabric/{site_name}-frr.conf').read_text()
    assert f'neighbor OCP remote-as {asn}' in conf
    assert 'neighbor OCP attribute-unchanged next-hop' in conf
    assert 'address-family l2vpn evpn' in conf
    assert not re.search(r'(?m)^\s+neighbor .*send-community.*\n\s+exit-address-family', conf)

cudn = manifest('shared/04-cudn.yaml')
assert cudn['spec']['network']['evpn']['macVRF'] == {'vni': 5050, 'routeTarget': '65000:5050'}
assert cudn['spec']['network']['layer2']['subnets'] == ['10.250.50.0/24']
assert manifest('shared/03-routeadvertisements.yaml')['spec']['targetVRF'] == 'auto'
assert (root / 'scripts/04-test.sh').read_text().find('ping -c 4 10.250.50.4') >= 0
assert '10.250.50.12' not in (root / 'scripts/04-test.sh').read_text()
assert len(all_vteps) == 14
print('PASS: 14 unique /32 VTEPs, peers, FRR configs, secure VM templates, CUDN and corrected test IP')
