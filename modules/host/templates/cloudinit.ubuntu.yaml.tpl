#cloud-config

debug: True

package_update: true
package_upgrade: true
packages:
  - telnet
  - vim
  - open-iscsi
  - nfs-common
  - policycoreutils
  - network-manager

write_files:

${cloudinit_write_files_common}

# Add ssh authorized keys
ssh_authorized_keys:
%{ for key in sshAuthorizedKeys ~}
  - ${key}
%{ endfor ~}

# Resize /var, not /, as that's the last partition in MicroOS image.
# @fixme growpart
# growpart:
#  devices: ["/var"]

# Make sure the hostname is set correctly
hostname: ${hostname}
preserve_hostname: true

runcmd:
- date >> /root/cloud-init-alive.txt

# let's prepare for NetworkManager to manage network
- |
  # 1. replace netplan files renderer with empty line
  for f in /etc/netplan/*.yaml ; do
    if [ -f $f ] ; then
      sed -i 's/renderer:/#renderer:/g' $f
    fi
  done
  # 2. create a new network configuration
  cat << EOF >> /etc/netplan/00-kube-hetzner-config.yaml
  network:
    version: 2
    renderer: NetworkManager
  EOF
  # 3. apply the new network configuration
  netplan apply
  # 4. restart network manager
  systemctl restart NetworkManager
  # 5. disable systemd-networkd
  systemctl disable systemd-networkd
  systemctl stop systemd-networkd
  systemctl enable NetworkManager
  # systemctl restart NetworkManager
  echo "NetworkManager is now managing network"

${cloudinit_runcmd_common}


  # - sed -i 's/[#]*PermitRootLogin yes/PermitRootLogin prohibit-password/g' /etc/ssh/sshd_config
  # - sed -i 's/[#]*PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
  # - systemctl restart ssh
  # - systemctl stop systemd-resolved
  # - systemctl disable systemd-resolved
  # - rm /etc/resolv.conf
  # - echo "nameserver 1.1.1.1" > /etc/resolv.conf
  # - echo "nameserver 1.0.0.1" >> /etc/resolv.conf
- echo -e 'blacklist {\n  devnode "^sd[a-z0-9]+"\n}\n' >> /etc/multipath.conf
- systemctl enable iscsid
- ln -s -f bash /bin/sh
- mkdir -p /var/lib/ca-certificates
- echo "$(date) - Terraform deployment successfully finished" > /etc/node-ready
