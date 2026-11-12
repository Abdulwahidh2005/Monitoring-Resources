locals {
  linux_vms   = { for name, vm in var.vms : name => vm if vm.os == "Linux" }
  windows_vms = { for name, vm in var.vms : name => vm if vm.os == "Windows" }
  vm_os_types = toset([for vm in values(var.vms) : vm.os])

  vm_ids = merge(
    { for name, vm in azurerm_linux_virtual_machine.linux_vms : name => vm.id },
    { for name, vm in azurerm_windows_virtual_machine.windows_vms : name => vm.id }
  )

  performance_counter_specifiers = {
    Linux = [
      "\\Processor(*)\\% Processor Time",
      "\\Memory(*)\\% Used Memory",
      "\\Logical Disk(*)\\% Used Space",
    ]
    Windows = [
      "\\Processor(_Total)\\% Processor Time",
      "\\Memory\\Available MBytes",
      "\\LogicalDisk(*)\\% Free Space",
    ]
  }

  data_collection_streams = {
    Linux   = ["Microsoft-Perf", "Microsoft-Syslog"]
    Windows = ["Microsoft-Perf", "Microsoft-Event"]
  }

  guest_errors_query = <<-KQL
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
  KQL

  low_memory_query = <<-KQL
    Perf
    | where TimeGenerated > ago(5m)
    | where tolower(_ResourceId) == "__TARGET_RESOURCE_ID__"
    | where ObjectName == "Memory"
    | where (CounterName == "% Used Memory" and CounterValue > ${var.memory_used_percent_threshold})
        or (CounterName == "Available MBytes" and CounterValue < ${var.available_memory_mb_threshold})
    | project TimeGenerated, _ResourceId, Computer, AlertValue = 1
  KQL

  low_disk_query = <<-KQL
    Perf
    | where TimeGenerated > ago(5m)
    | where tolower(_ResourceId) == "__TARGET_RESOURCE_ID__"
    | where InstanceName != "_Total"
    | where (ObjectName == "Logical Disk" and CounterName == "% Used Space"
        and 100.0 - CounterValue < ${var.disk_free_space_threshold_percent})
        or (ObjectName == "LogicalDisk" and CounterName == "% Free Space"
        and CounterValue < ${var.disk_free_space_threshold_percent})
    | project TimeGenerated, _ResourceId, Computer, AlertValue = 1
  KQL

  log_alert_queries = {
    guest_errors = {
      name        = var.guest_errors_alert_name
      description = "Alerts on guest OS errors for the explicitly listed VM."
      query       = local.guest_errors_query
    }
    low_memory = {
      name        = var.low_memory_alert_name
      description = "Alerts on low available memory for the explicitly listed VM."
      query       = local.low_memory_query
    }
    low_disk = {
      name        = var.low_disk_alert_name
      description = "Alerts on low disk free space for the explicitly listed VM."
      query       = local.low_disk_query
    }
  }

  log_alert_rule_instances = merge([
    for alert_key, alert in local.log_alert_queries : {
      for vm_name, vm_id in local.vm_ids : "${alert_key}-${vm_name}" => {
        alert_key   = alert_key
        alert_name  = alert.name
        description = "${alert.description} VM: ${vm_name}."
        vm_name     = vm_name
        vm_id       = vm_id
        query       = replace(alert.query, "__TARGET_RESOURCE_ID__", lower(vm_id))
      }
    }
  ]...)

  heartbeat_queries = {
    for name, vm in var.vms : name => <<-KQL
      let targetResourceId = "${lower(local.vm_ids[name])}";
      let lastHeartbeat = toscalar(
        Heartbeat
        | where TimeGenerated > ago(2d)
        | where tolower(_ResourceId) == targetResourceId
        | summarize max(TimeGenerated)
      );
      print TimeGenerated = now(), _ResourceId = targetResourceId,
        AlertValue = iff(isnull(lastHeartbeat) or lastHeartbeat < ago(15m), 1, 0)
      | where AlertValue > 0
    KQL
  }
}
