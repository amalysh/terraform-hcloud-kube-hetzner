#cloud-config

package_update: true
package_upgrade: true
packages:
  - telnet
  - vim
  - open-iscsi
  - nfs-common
  - policycoreutils
  - network-manager
  - cryptsetup

write_files:

${cloudinit_write_files_common}

- content: ${base64encode(k3s_config)}
  encoding: base64
  path: /tmp/config.yaml

- content: ${base64encode(install_k3s_agent_script)}
  encoding: base64
  path: /var/pre_install/install-k3s-agent.sh

# DEBUG: root password for console access
# users:
#   - name: root
#     plain_text_passwd: test12345
#     lock_passwd: false
# ssh_pwauth: true

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

# Switch to NetworkManager as sole network manager
- |
  # Tell netplan to use NetworkManager as backend for all existing configs
  cat > /etc/netplan/00-kube-hetzner-config.yaml <<'EOF'
  network:
    version: 2
    renderer: NetworkManager
  EOF
  chmod 600 /etc/netplan/00-kube-hetzner-config.yaml
  # Remove any explicit 'renderer: networkd' from existing netplan configs
  # so our 00-kube-hetzner-config.yaml global renderer (NetworkManager) wins
  sed -i '/^\s*renderer:\s*networkd/d' /etc/netplan/*.yaml
  # Apply: converts existing netplan configs into NM keyfiles
  netplan apply
  systemctl restart NetworkManager
  # Hard-disable systemd-networkd
  systemctl stop systemd-networkd.socket systemd-networkd
  systemctl disable systemd-networkd.socket systemd-networkd
  systemctl mask systemd-networkd.socket systemd-networkd
  # Ensure NetworkManager is active
  systemctl enable --now NetworkManager
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
- echo 'blacklist {\n  devnode "^sd[a-z0-9]+"\n}\n' >> /etc/multipath.conf
- systemctl enable iscsid
- modprobe dm_crypt
- echo dm_crypt > /etc/modules-load.d/dm_crypt.conf
- ln -s -f bash /bin/sh
- mkdir -p /var/lib/ca-certificates
- echo "$(date) - Terraform deployment successfully finished" > /etc/node-ready

# Bare metal routing (WireGuard gateway mode, empty if no external nodes)
${baremetal_runcmd}

# Start the install-k3s-agent service
- ['/bin/bash', '/var/pre_install/install-k3s-agent.sh']

# Reboot if kernel was updated to ensure new kernel is loaded
power_state:
  delay: 0
  mode: reboot
  message: "Rebooting after cloud-init to load updated kernel"
  condition: test -f /var/run/reboot-required
