# VM Monitoring Overview

## Purpose and scope

This document describes the Azure Monitor resources and alert rules declared by
this Terraform configuration. It is intended as a team reference for where VM
telemetry comes from, how each alert evaluates, and how to investigate results.

The current `terraform.tfvars` lists two VMs:

| VM | Operating system |
|---|---|
| `linux-vm` | Linux |
| `windows-vm` | Windows |

The counts and generated names below are based on those two entries. Terraform
configuration describes the desired setup; it does not by itself prove that
resources have been applied successfully or that alerts have fired.

## Monitoring resources

| Resource | Current count | Purpose |
|---|---:|---|
| Log Analytics workspace | 1 | Destination and query surface for guest performance counters, heartbeat, Syslog, and Windows events. Name: `la-customvm-uks-001`; configured retention: 30 days. |
| Azure Monitor Agent (AMA) VM extension | 2 | Installed on each VM to collect and send guest telemetry. |
| Data Collection Rule (DCR) | 2 | One OS-specific DCR for Linux and one for Windows. Names are based on `dcr-customvm-uks-001` with `-linux` and `-windows` suffixes. |
| DCR association | 2 | Associates each VM with the DCR for its operating system. |
| Alert rules | 9 | 1 Azure platform metric alert and 8 scheduled-query (log) alerts. |

The DCR sends data to the workspace through the `Microsoft-Perf` stream for
both operating systems, `Microsoft-Syslog` for Linux, and `Microsoft-Event`
for Windows. Performance counters are collected every 60 seconds.

| OS | Collected performance counters | Additional data |
|---|---|---|
| Linux | Processor `\\Processor(*)\\% Processor Time`; memory `\\Memory(*)\\% Used Memory`; disk `\\Logical Disk(*)\\% Used Space` | All configured Syslog facilities and levels |
| Windows | Processor `\\Processor(_Total)\\% Processor Time`; memory `\\Memory\\Available MBytes`; disk `\\LogicalDisk(*)\\% Free Space` | System and Application events at Error or Critical levels |

## Alert inventory

Terraform uses the current name prefixes from `terraform.tfvars`. Per-VM log
rule names append the VM name to the prefix. All rules are enabled.

| Alert name(s) | Type | Count | Scope / severity | Signal and trigger |
|---|---|---:|---|---|
| `vm-high-cpu` | Metric | 1 | Both VMs; severity 2 | Azure platform metric `Percentage CPU`, Average greater than 20%, evaluated every 1 minute over a 5-minute window. No KQL is used. |
| `vm-guest-errors-linux-vm`, `vm-guest-errors-windows-vm` | Log (scheduled query) | 2 | One VM per rule; severity 2 | Syslog error/critical levels on Linux, or System/Application Error/Critical events on Windows, found in the last 5 minutes. |
| `vm-low-memory-linux-vm`, `vm-low-memory-windows-vm` | Log (scheduled query) | 2 | One VM per rule; severity 2 | Linux `% Used Memory` greater than 10%, or Windows `Available MBytes` below 2,000 MB. |
| `vm-low-disk-space-linux-vm`, `vm-low-disk-space-windows-vm` | Log (scheduled query) | 2 | One VM per rule; severity 2 | Linux free disk percentage below 90% (calculated from `% Used Space`), or Windows `% Free Space` below 90%. |
| `vm-missing-heartbeat-linux-vm`, `vm-missing-heartbeat-windows-vm` | Log (scheduled query) | 2 | One VM per rule; severity 1 | Fires when no heartbeat has been recorded for the VM in the last 15 minutes. |

Scheduled-query alerts evaluate every 5 minutes. The guest error, memory, and
disk alerts query a 5-minute time range. Heartbeat alerts query up to 2 days of
heartbeat data so they can identify a missing recent heartbeat. All scheduled
query rules trigger when the query returns an `AlertValue` greater than zero;
auto-mitigation is enabled.

The configured thresholds above are the current values found in
`terraform.tfvars`. Threshold edits take effect in Azure only after a successful
`terraform apply`.

With the current test thresholds, the Linux memory condition (`% Used Memory`
greater than 10%) and disk condition (free space below 90%) may be true during
ordinary operation. These settings are useful for exercising alert delivery,
but may be noisy; restore operational thresholds after testing and apply them.
For a VM map containing `N` VMs, Terraform creates one shared CPU metric alert,
three guest log alerts per VM, and one heartbeat log alert per VM, for
`1 + 4N` alert rules in total.

## KQL used by log alerts

The following queries show the Terraform query templates. At deployment,
Terraform replaces `__TARGET_RESOURCE_ID__` with the lowercase Azure resource
ID of the VM associated with that alert. Threshold placeholders are rendered
from the Terraform variables.

### Guest OS errors

Used by `vm-guest-errors-<vm-name>`. It searches the Linux `Syslog` table and
Windows `Event` table, matching the VM resource ID and selecting the configured
error severity levels.

```kusto
union isfuzzy=true
(
  Syslog
  | where TimeGenerated > ago(5m)
  | where tolower(_ResourceId) == "__TARGET_RESOURCE_ID__"
  | where SeverityLevel in ("err", "crit", "alert", "emerg")
  | project TimeGenerated, _ResourceId, Computer, AlertValue = 1
),
(
  Event
  | where TimeGenerated > ago(5m)
  | where tolower(_ResourceId) == "__TARGET_RESOURCE_ID__"
  | where EventLog in ("System", "Application")
  | where EventLevelName in ("Error", "Critical")
  | project TimeGenerated, _ResourceId, Computer, AlertValue = 1
)
```

### Low memory

Used by `vm-low-memory-<vm-name>`. The Linux branch detects memory used above
`memory_used_percent_threshold` (currently 10). The Windows branch detects
available memory below `available_memory_mb_threshold` (currently 2,000 MB).

```kusto
Perf
| where TimeGenerated > ago(5m)
| where tolower(_ResourceId) == "__TARGET_RESOURCE_ID__"
| where ObjectName == "Memory"
| where (CounterName == "% Used Memory" and CounterValue > 10)
    or (CounterName == "Available MBytes" and CounterValue < 2000)
| project TimeGenerated, _ResourceId, Computer, AlertValue = 1
```

### Low disk space

Used by `vm-low-disk-space-<vm-name>`. For Linux, free percentage is computed
as `100 - % Used Space`; for Windows the `% Free Space` counter is compared
directly. The threshold is currently 90%.

```kusto
Perf
| where TimeGenerated > ago(5m)
| where tolower(_ResourceId) == "__TARGET_RESOURCE_ID__"
| where InstanceName != "_Total"
| where (ObjectName == "Logical Disk" and CounterName == "% Used Space"
    and 100.0 - CounterValue < 90)
    or (ObjectName == "LogicalDisk" and CounterName == "% Free Space"
    and CounterValue < 90)
| project TimeGenerated, _ResourceId, Computer, AlertValue = 1
```

### Missing heartbeat

Used by `vm-missing-heartbeat-<vm-name>`. Each rule receives a VM-specific
resource ID from Terraform.

```kusto
let targetResourceId = "<lowercase VM resource ID>";
let lastHeartbeat = toscalar(
  Heartbeat
  | where TimeGenerated > ago(2d)
  | where tolower(_ResourceId) == targetResourceId
  | summarize max(TimeGenerated)
);
print TimeGenerated = now(), _ResourceId = targetResourceId,
  AlertValue = iff(isnull(lastHeartbeat) or lastHeartbeat < ago(15m), 1, 0)
| where AlertValue > 0
```

## Where to view and investigate telemetry

1. In Azure Portal, open **Monitor → Alerts**. Filter to the VM resource group,
   select an appropriate time range, and inspect the alert rule name and fired
   time.
2. Open the configured Log Analytics workspace and select **Logs** to run
   queries against `Perf`, `Heartbeat`, `Syslog`, or `Event`.
3. If an alert has no data, check the VM's AMA extension, its DCR association,
   the OS-specific DCR destination, and recent data arrival in the workspace.
4. Allow for the collection interval, ingestion delay, and alert evaluation
   interval. Guest performance samples are collected every 60 seconds and log
   alerts evaluate every 5 minutes.

Example query for recent guest performance data:

```kusto
Perf
| where TimeGenerated > ago(30m)
| where ObjectName in ("Processor", "Memory", "Logical Disk", "LogicalDisk")
| project TimeGenerated, Computer, ObjectName, CounterName, InstanceName, CounterValue
| order by TimeGenerated desc
```

Example query for recent heartbeat data:

```kusto
Heartbeat
| where TimeGenerated > ago(2h)
| summarize LastHeartbeat = max(TimeGenerated) by Computer, _ResourceId
| order by LastHeartbeat desc
```

## Configuration references

- `monitor.tf` declares the workspace, AMA extensions, DCRs, DCR associations,
  and alert resources.
- `local.tf` defines collected counters and the KQL query templates.
- `variables.tf` defines the default alert thresholds and evaluation settings.
- `terraform.tfvars` supplies the current VM names, alert name prefixes, and
  threshold overrides.
- `outputs.tf` exposes workspace and DCR IDs, alert rule IDs, and VM IDs.
