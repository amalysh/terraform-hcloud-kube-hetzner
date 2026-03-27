[Interface]
Address = ${address}
ListenPort = ${listen_port}
PrivateKey = ${private_key}
%{ for peer in peers ~}

[Peer]
PublicKey = ${peer.public_key}
Endpoint = ${peer.endpoint}
AllowedIPs = ${peer.allowed_ips}
PersistentKeepalive = 25
%{ endfor ~}
