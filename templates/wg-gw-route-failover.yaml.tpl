---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: wg-gw-route-failover
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: wg-gw-route-failover
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["list"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "create", "update", "patch"]
    resourceNames: ["wg-gw-gateway"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: wg-gw-route-failover
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: wg-gw-route-failover
subjects:
  - kind: ServiceAccount
    name: wg-gw-route-failover
    namespace: kube-system
---
# ConfigMap storing the current gateway CP IP — source of truth for both
# the CronJob (writes) and the DaemonSet on external nodes (reads + applies wg set)
apiVersion: v1
kind: ConfigMap
metadata:
  name: wg-gw-gateway
  namespace: kube-system
data:
  gateway-cp-ip: "${initial_gateway_cp_ip}"
  cp-peers: |
    ${cp_peers_json}
---
# CronJob: monitors CP health, updates Hetzner route + ConfigMap on failure
apiVersion: batch/v1
kind: CronJob
metadata:
  name: wg-gw-route-failover
  namespace: kube-system
spec:
  schedule: "*/1 * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 50
      template:
        spec:
          serviceAccountName: wg-gw-route-failover
          restartPolicy: Never
          tolerations:
            - key: "node-role.kubernetes.io/control-plane"
              operator: Exists
              effect: NoSchedule
            - key: "node-role.kubernetes.io/master"
              operator: Exists
              effect: NoSchedule
          nodeSelector:
            node-role.kubernetes.io/control-plane: "true"
          containers:
            - name: failover
              image: bitnami/kubectl:latest
              env:
                - name: HCLOUD_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: hcloud
                      key: token
                - name: NETWORK_ID
                  value: "${network_id}"
              command:
                - /bin/sh
                - -c
                - |
                  set -e

                  # Configuration
                  CP_IPS="${cp_private_ips}"
                  EXTERNAL_WG_IPS="${external_wg_ips}"

                  # Get list of Ready control plane nodes
                  READY_CP_IPS=""
                  NODES_JSON=$(kubectl get nodes -o json 2>/dev/null)
                  for ip in $CP_IPS; do
                    IS_READY=$(echo "$NODES_JSON" | jq -r \
                      --arg ip "$ip" \
                      '.items[] | select(.status.addresses[] | select(.type=="InternalIP" and .address==$ip)) | .status.conditions[] | select(.type=="Ready") | .status' \
                      2>/dev/null)
                    if [ "$IS_READY" = "True" ]; then
                      READY_CP_IPS="$READY_CP_IPS $ip"
                    fi
                  done

                  if [ -z "$READY_CP_IPS" ]; then
                    echo "CRITICAL: No Ready CPs found! Leaving routes unchanged."
                    exit 1
                  fi

                  FIRST_READY=$(echo $READY_CP_IPS | awk '{print $1}')

                  # Get current gateway from ConfigMap
                  CURRENT_GW=$(kubectl get configmap -n kube-system wg-gw-gateway -o jsonpath='{.data.gateway-cp-ip}' 2>/dev/null)

                  # Check if current gateway is healthy
                  GW_HEALTHY=false
                  for ip in $READY_CP_IPS; do
                    if [ "$ip" = "$CURRENT_GW" ]; then
                      GW_HEALTHY=true
                      break
                    fi
                  done

                  if [ "$GW_HEALTHY" = "true" ]; then
                    echo "OK: gateway $CURRENT_GW (healthy)"
                  else
                    echo "FAILOVER: gateway $CURRENT_GW (unhealthy) -> $FIRST_READY"

                    # Update Hetzner network routes for each external node
                    for ext_ip in $EXTERNAL_WG_IPS; do
                      DEST="$ext_ip/32"
                      curl -sf -X POST -H "Authorization: Bearer $HCLOUD_TOKEN" \
                        -H "Content-Type: application/json" \
                        -d "{\"destination\":\"$DEST\",\"gateway\":\"$CURRENT_GW\"}" \
                        "https://api.hetzner.cloud/v1/networks/$NETWORK_ID/actions/delete_route" > /dev/null || true
                      sleep 2
                      curl -sf -X POST -H "Authorization: Bearer $HCLOUD_TOKEN" \
                        -H "Content-Type: application/json" \
                        -d "{\"destination\":\"$DEST\",\"gateway\":\"$FIRST_READY\"}" \
                        "https://api.hetzner.cloud/v1/networks/$NETWORK_ID/actions/add_route" > /dev/null
                      echo "Route updated: $DEST -> $FIRST_READY"
                    done

                    # Update ConfigMap — DaemonSet on external nodes will pick this up
                    kubectl patch configmap -n kube-system wg-gw-gateway \
                      -p "{\"data\":{\"gateway-cp-ip\":\"$FIRST_READY\"}}"
                    echo "ConfigMap updated: gateway -> $FIRST_READY"
                  fi
---
# DaemonSet: runs on external nodes, watches ConfigMap, applies wg set
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: wg-gw-watcher
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: wg-gw-watcher
  template:
    metadata:
      labels:
        app: wg-gw-watcher
    spec:
      serviceAccountName: wg-gw-route-failover
      hostNetwork: true
      hostPID: true
      tolerations:
        - operator: Exists
      nodeSelector:
        instance.hetzner.cloud/provided-by: external
      containers:
        - name: watcher
          image: bitnami/kubectl:latest
          securityContext:
            privileged: true
            runAsUser: 0
          command:
            - /bin/sh
            - -c
            - |
              echo "wg-gw-watcher starting on $(hostname)"
              CP_PEERS=$(kubectl get configmap -n kube-system wg-gw-gateway -o jsonpath='{.data.cp-peers}' 2>/dev/null)
              NETWORK_CIDR=${network_cidr}
              CURRENT_GW=""

              while true; do
                # Read desired gateway from ConfigMap
                DESIRED_GW=$(kubectl get configmap -n kube-system wg-gw-gateway \
                  -o jsonpath='{.data.gateway-cp-ip}' 2>/dev/null)

                if [ -z "$DESIRED_GW" ]; then
                  sleep 15
                  continue
                fi

                if [ "$DESIRED_GW" != "$CURRENT_GW" ] && [ -n "$CURRENT_GW" ]; then
                  echo "Gateway changed: $CURRENT_GW -> $DESIRED_GW"

                  # Find public keys for old and new gateway CPs
                  OLD_PUBKEY=$(echo "$CP_PEERS" | jq -r --arg ip "$CURRENT_GW" '.[] | select(.ip==$ip) | .pubkey' 2>/dev/null)
                  NEW_PUBKEY=$(echo "$CP_PEERS" | jq -r --arg ip "$DESIRED_GW" '.[] | select(.ip==$ip) | .pubkey' 2>/dev/null)
                  OLD_WG_IP=$(echo "$CP_PEERS" | jq -r --arg ip "$CURRENT_GW" '.[] | select(.ip==$ip) | .wg_ip // empty' 2>/dev/null)
                  NEW_WG_IP=$(echo "$CP_PEERS" | jq -r --arg ip "$DESIRED_GW" '.[] | select(.ip==$ip) | .wg_ip // empty' 2>/dev/null)

                  if [ -n "$OLD_PUBKEY" ] && [ -n "$NEW_PUBKEY" ]; then
                    # Remove broad CIDR from old gateway
                    OLD_ALLOWED="$CURRENT_GW/32"
                    [ -n "$OLD_WG_IP" ] && OLD_ALLOWED="$OLD_ALLOWED,$OLD_WG_IP/32"
                    nsenter -t 1 -m -n -- wg set wg-mesh peer "$OLD_PUBKEY" allowed-ips "$OLD_ALLOWED" 2>&1 && \
                      echo "Removed $NETWORK_CIDR from $CURRENT_GW"

                    # Add broad CIDR to new gateway
                    NEW_ALLOWED="$DESIRED_GW/32,$NETWORK_CIDR"
                    [ -n "$NEW_WG_IP" ] && NEW_ALLOWED="$NEW_ALLOWED,$NEW_WG_IP/32"
                    nsenter -t 1 -m -n -- wg set wg-mesh peer "$NEW_PUBKEY" allowed-ips "$NEW_ALLOWED" 2>&1 && \
                      echo "Added $NETWORK_CIDR to $DESIRED_GW"
                  else
                    echo "WARNING: Could not find pubkeys for $CURRENT_GW or $DESIRED_GW"
                  fi
                fi

                CURRENT_GW="$DESIRED_GW"
                sleep 15
              done
