---
# Doc: https://rancher.com/docs/k3s/latest/en/upgrades/automated/
# agent plan
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: k3s-agent
  namespace: system-upgrade
  labels:
    k3s_upgrade: agent
spec:
  concurrency: 1
  # SUC's default ActiveDeadlineSeconds is 600s. Robot-node RWO drains take ~10-15min,
  # so at 600s the drain is killed mid-way, leaving Longhorn volumes still attached when
  # k3s restarts + the instance-manager pod is recreated with a new IP -> orphaned
  # iSCSI sessions (REOPEN-stuck, error 32) that block re-attach, plus a stuck-cordoned
  # node. A generous deadline lets the eviction-honoring drain finish so volumes detach
  # (engine logout) cleanly before the IM is recreated -> no orphan.
  jobActiveDeadlineSecs: 1800
  %{~ if longhorn ~}
  # Pause between agent nodes so Longhorn can rebuild the replicas that the
  # previous node's drain and instance-manager restart took away. Without it SUC
  # starts the next node as soon as the previous job completes, volumes lose
  # several replicas at once, and the resulting rebuild storm can hit Longhorn
  # rebuild races (longhorn/longhorn#13914). A fixed delay never blocks the roll,
  # unlike a "wait for 0 degraded volumes" gate, which would stall on any volume
  # that was already degraded before the roll began.
  postCompleteDelay: 30m
  %{~ endif ~}
  %{~ if version == "" ~}
  channel: https://update.k3s.io/v1-release/channels/${channel}
  %{~ else ~}
  version: ${version}
  %{~ endif ~}
  serviceAccountName: system-upgrade
  nodeSelector:
    matchExpressions:
      - {key: k3s_upgrade, operator: Exists}
      - {key: k3s_upgrade, operator: NotIn, values: ["disabled", "false"]}
      - {key: node-role.kubernetes.io/control-plane, operator: NotIn, values: ["true"]}
      - {key: kured, operator: NotIn, values: ["rebooting"]}
  tolerations:
    - {key: server-usage, effect: NoSchedule, operator: Equal, value: storage}
    - {operator: Exists}
  prepare:
    image: rancher/k3s-upgrade
    args: ["prepare", "k3s-server"]
  %{ if drain }drain:
    force: true
    disableEviction: ${disable_eviction}
    skipWaitForDeleteTimeout: 60%{ endif }
  %{ if !drain }cordon: true%{ endif }
  %{~ if upgrade_window != null ~}
  window:
    %{~ if length(try(upgrade_window.days, [])) > 0 ~}
    days:
      %{~ for day in try(upgrade_window.days, []) ~}
      - ${jsonencode(day)}
      %{~ endfor ~}
    %{~ endif ~}
    %{~ if coalesce(try(upgrade_window.startTime, ""), "") != "" ~}
    startTime: ${jsonencode(coalesce(try(upgrade_window.startTime, ""), ""))}
    %{~ endif ~}
    %{~ if coalesce(try(upgrade_window.endTime, ""), "") != "" ~}
    endTime: ${jsonencode(coalesce(try(upgrade_window.endTime, ""), ""))}
    %{~ endif ~}
    %{~ if coalesce(try(upgrade_window.timeZone, ""), "") != "" ~}
    timeZone: ${jsonencode(coalesce(try(upgrade_window.timeZone, ""), ""))}
    %{~ endif ~}
  %{~ endif ~}
  upgrade:
    image: rancher/k3s-upgrade
---
# server plan
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: k3s-server
  namespace: system-upgrade
  labels:
    k3s_upgrade: server
spec:
  concurrency: 1
  %{~ if version == "" ~}
  channel: https://update.k3s.io/v1-release/channels/${channel}
  %{~ else ~}
  version: ${version}
  %{~ endif ~}
  serviceAccountName: system-upgrade
  nodeSelector:
    matchExpressions:
      - {key: k3s_upgrade, operator: Exists}
      - {key: k3s_upgrade, operator: NotIn, values: ["disabled", "false"]}
      - {key: node-role.kubernetes.io/control-plane, operator: In, values: ["true"]}
      - {key: kured, operator: NotIn, values: ["rebooting"]}
  tolerations:
    - {key: node-role.kubernetes.io/control-plane, effect: NoSchedule, operator: Exists}
    - {key: CriticalAddonsOnly, effect: NoExecute, operator: Exists}
  cordon: true
  %{~ if upgrade_window != null ~}
  window:
    %{~ if length(try(upgrade_window.days, [])) > 0 ~}
    days:
      %{~ for day in try(upgrade_window.days, []) ~}
      - ${jsonencode(day)}
      %{~ endfor ~}
    %{~ endif ~}
    %{~ if coalesce(try(upgrade_window.startTime, ""), "") != "" ~}
    startTime: ${jsonencode(coalesce(try(upgrade_window.startTime, ""), ""))}
    %{~ endif ~}
    %{~ if coalesce(try(upgrade_window.endTime, ""), "") != "" ~}
    endTime: ${jsonencode(coalesce(try(upgrade_window.endTime, ""), ""))}
    %{~ endif ~}
    %{~ if coalesce(try(upgrade_window.timeZone, ""), "") != "" ~}
    timeZone: ${jsonencode(coalesce(try(upgrade_window.timeZone, ""), ""))}
    %{~ endif ~}
  %{~ endif ~}
  upgrade:
    image: rancher/k3s-upgrade
