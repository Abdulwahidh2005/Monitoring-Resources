resource "azurerm_log_analytics_workspace" "monitoring_workspace" {
  name                = var.log_analytics_workspace_name
  location            = var.location
  resource_group_name = azurerm_resource_group.monitoring.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  tags                = var.tags
}

resource "azurerm_virtual_machine_extension" "azure_monitor_agent" {
  for_each                   = var.vms
  name                       = each.value.os == "Windows" ? "AzureMonitorWindowsAgent" : "AzureMonitorLinuxAgent"
  virtual_machine_id         = local.vm_ids[each.key]
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = each.value.os == "Windows" ? "AzureMonitorWindowsAgent" : "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
  settings                   = jsonencode({})
  tags                       = var.tags
}

resource "azurerm_monitor_data_collection_rule" "guest_data_collection_rules" {
  for_each            = local.vm_os_types
  name                = "${var.dcr_name}-${lower(each.key)}"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = var.location
  kind                = each.key
  tags                = var.tags

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.monitoring_workspace.id
      name                  = "log-analytics"
    }
  }

  data_flow {
    streams      = local.data_collection_streams[each.key]
    destinations = ["log-analytics"]
  }

  data_sources {
    performance_counter {
      name                          = "guest-performance"
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = 60
      counter_specifiers            = local.performance_counter_specifiers[each.key]
    }

    dynamic "syslog" {
      for_each = each.key == "Linux" ? [1] : []

      content {
        name           = "guest-syslog"
        streams        = ["Microsoft-Syslog"]
        facility_names = ["*"]
        log_levels     = ["*"]
      }
    }

    dynamic "windows_event_log" {
      for_each = each.key == "Windows" ? [1] : []

      content {
        name    = "guest-windows-events"
        streams = ["Microsoft-Event"]
        x_path_queries = [
          "System!*[System[(Level=1 or Level=2)]]",
          "Application!*[System[(Level=1 or Level=2)]]",
        ]
      }
    }
  }

  depends_on = [azurerm_log_analytics_workspace.monitoring_workspace]
}

resource "azurerm_monitor_data_collection_rule_association" "vm_dcr_associations" {
  for_each                = var.vms
  name                    = "${each.key}-dcr-association"
  target_resource_id      = local.vm_ids[each.key]
  data_collection_rule_id = azurerm_monitor_data_collection_rule.guest_data_collection_rules[each.value.os].id

  depends_on = [
    azurerm_virtual_machine_extension.azure_monitor_agent,
    azurerm_monitor_data_collection_rule.guest_data_collection_rules,
  ]
}

resource "azurerm_monitor_metric_alert" "high_cpu" {
  name                     = var.cpu_alert_name
  resource_group_name      = azurerm_resource_group.monitoring.name
  scopes                   = values(local.vm_ids)
  target_resource_type     = "Microsoft.Compute/virtualMachines"
  target_resource_location = var.location
  description              = "Average CPU utilization on virtual machines in ${var.vm_resource_group_name} is above ${var.cpu_threshold_percent}%."
  frequency                = var.evaluation_frequency
  window_size              = "PT5M"
  severity                 = 2
  enabled                  = true
  tags                     = var.tags

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.cpu_threshold_percent
  }

}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "guest_log_alerts" {
  for_each = local.log_alert_rule_instances

  name                      = "${each.value.alert_name}-${each.value.vm_name}"
  display_name              = "${each.value.alert_name}-${each.value.vm_name}"
  resource_group_name       = azurerm_resource_group.monitoring.name
  location                  = var.location
  description               = each.value.description
  evaluation_frequency      = var.log_alert_evaluation_frequency
  window_duration           = "PT5M"
  scopes                    = [each.value.vm_id]
  severity                  = 2
  enabled                   = true
  auto_mitigation_enabled   = true
  query_time_range_override = "PT5M"
  tags                      = var.tags

  criteria {
    query                   = each.value.query
    time_aggregation_method = "Maximum"
    metric_measure_column   = "AlertValue"
    resource_id_column      = "_ResourceId"
    operator                = "GreaterThan"
    threshold               = 0

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }


  depends_on = [azurerm_monitor_data_collection_rule_association.vm_dcr_associations]
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "vm_heartbeat_alerts" {
  for_each = local.heartbeat_queries

  name                      = "${var.availability_alert_name}-${each.key}"
  display_name              = "${var.availability_alert_name}-${each.key}"
  resource_group_name       = azurerm_resource_group.monitoring.name
  location                  = var.location
  description               = "Alerts when ${each.key} has no recent Azure Monitor heartbeat."
  evaluation_frequency      = var.log_alert_evaluation_frequency
  window_duration           = "PT5M"
  query_time_range_override = "P2D"
  scopes                    = [local.vm_ids[each.key]]
  severity                  = 1
  enabled                   = true
  auto_mitigation_enabled   = true
  tags                      = var.tags

  criteria {
    query                   = each.value
    time_aggregation_method = "Maximum"
    metric_measure_column   = "AlertValue"
    resource_id_column      = "_ResourceId"
    operator                = "GreaterThan"
    threshold               = 0

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  depends_on = [azurerm_monitor_data_collection_rule_association.vm_dcr_associations]
}
