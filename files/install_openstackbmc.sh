#!/bin/bash
# This file taken from: https://raw.githubusercontent.com/cybertron/openstack-virtual-baremetal/master/bin/install_openstackbmc.sh
set -x

yum -y update centos-release # required for rdo-release install to work
yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
yum install -y https://rdo.fedorapeople.org/rdo-release.rpm
yum install -y python-pip python-crypto os-net-config python-novaclient python-neutronclient git jq
pip install pyghmi

cat <<EOF >/usr/local/bin/openstackbmc
$openstackbmc_script
EOF
chmod +x /usr/local/bin/openstackbmc

export OS_USERNAME=$os_user
export OS_TENANT_NAME=$os_tenant
export OS_PASSWORD=$os_password
export OS_AUTH_URL=$os_auth_url
private_subnet=$(neutron net-show -f value -c subnets $private_net)
default_gw=$(neutron subnet-show $private_subnet -f value -c gateway_ip)
prefix_len=$(neutron subnet-show -f value -c cidr $private_subnet | awk -F / '{print $2}')

mkdir /etc/os-net-config
echo "network_config:" > /etc/os-net-config/config.yaml
echo "  -" >> /etc/os-net-config/config.yaml
echo "    type: interface" >> /etc/os-net-config/config.yaml
echo "    name: eth0" >> /etc/os-net-config/config.yaml
echo "    use_dhcp: false" >> /etc/os-net-config/config.yaml
echo "    mtu: 1450" >> /etc/os-net-config/config.yaml
echo "    routes:" >> /etc/os-net-config/config.yaml
echo "      - default: true" >> /etc/os-net-config/config.yaml
echo "        next_hop: $default_gw" >> /etc/os-net-config/config.yaml
echo "    addresses:" >> /etc/os-net-config/config.yaml
echo "    - ip_netmask: $bmc_utility/$prefix_len" >> /etc/os-net-config/config.yaml

cat <<EOF >/usr/lib/systemd/system/config-bmc-ips.service
[Unit]
Description=config-bmc-ips Service
Requires=network.target
After=network.target

[Service]
ExecStart=/bin/os-net-config --verbose
Type=oneshot
User=root
StandardOutput=kmsg+console
StandardError=inherit

[Install]
WantedBy=multi-user.target
EOF

for i in $(seq 1 $bm_node_count)
do
    bm_port="$bm_prefix_$(($i-1))"
    bm_instance=$(neutron port-show $bm_port -c device_id -f value)
    bmc_port="$bmc_prefix_$(($i-1))"
    bmc_ip=$(neutron port-show $bmc_port -c fixed_ips -f value | jq -r .ip_address)
    unit="openstack-bmc-$bm_port.service"

    cat <<EOF >/usr/lib/systemd/system/$unit
[Unit]
Description=openstack-bmc $bm_port Service
Requires=config-bmc-ips.service
After=config-bmc-ips.service

[Service]
ExecStart=/usr/local/bin/openstackbmc  --os-user $os_user --os-password $os_password --os-tenant $os_tenant --os-auth-url $os_auth_url --instance $bm_instance --address $bmc_ip

User=root
StandardOutput=kmsg+console
StandardError=inherit

[Install]
WantedBy=multi-user.target
EOF

    echo "    - ip_netmask: $bmc_ip/$prefix_len" >> /etc/os-net-config/config.yaml
done

# It will be automatically started because the bmc services depend on it,
# but to avoid confusion also explicitly enable it.
systemctl enable config-bmc-ips

for i in $(seq 1 $bm_node_count)
do
    bm_port="$bm_prefix_$(($i-1))"
    unit="openstack-bmc-$bm_port.service"
    systemctl enable $unit
    systemctl start $unit
    systemctl status $unit
done
