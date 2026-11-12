output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.monitoring_workspace.id
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.monitoring_workspace.name
}

output "dcr_ids" {
  description = "Resource IDs of the OS-specific Data Collection Rules."
  value       = { for os, dcr in azurerm_monitor_data_collection_rule.guest_data_collection_rules : os => dcr.id }
}

output "alert_rule_ids" {
  description = "Resource IDs of the shared CPU/log rules and per-VM heartbeat rules."
  value = merge(
    {
      high_cpu = azurerm_monitor_metric_alert.high_cpu.id
    },
    {
      for alert_name, alert in azurerm_monitor_scheduled_query_rules_alert_v2.guest_log_alerts :
      alert_name => alert.id
    },
    {
      for vm_name, alert in azurerm_monitor_scheduled_query_rules_alert_v2.vm_heartbeat_alerts :
      "heartbeat_${vm_name}" => alert.id
    }
  )
}

output "vm_ids" {
  description = "Resource IDs of all created virtual machines, keyed by VM name."
  value       = local.vm_ids
}

output "vm_private_ip_addresses" {
  description = "Private IP addresses of all created VMs, keyed by VM name."
  value       = { for name, nic in azurerm_network_interface.vm_nics : name => nic.private_ip_address }
}

output "vm_public_ip_addresses" {
  description = "Static public IP addresses of all created VMs, keyed by VM name."
  value       = { for name, ip in azurerm_public_ip.vm_public_ips : name => ip.ip_address }
}
