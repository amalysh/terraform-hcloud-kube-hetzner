---
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: metallb
  namespace: kube-system
spec:
  chart: metallb
  repo: https://metallb.github.io/metallb
  version: "${version}"
  targetNamespace: metallb-system
  bootstrap: true
  valuesContent: |-
    ${values}
---
# IPAddressPool and L2Advertisement are applied after MetalLB is installed
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - ${address_pool}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
