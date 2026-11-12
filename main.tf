resource "azurerm_resource_group" "monitoring" {
  name     = var.vm_resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "vm_network" {
  name                = "${var.vm_resource_group_name}-vnet"
  location            = azurerm_resource_group.monitoring.location
  resource_group_name = azurerm_resource_group.monitoring.name
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "vm_subnet" {
  name                 = "${var.vm_resource_group_name}-subnet"
  resource_group_name  = azurerm_resource_group.monitoring.name
  virtual_network_name = azurerm_virtual_network.vm_network.name
  address_prefixes     = var.subnet_address_prefixes
}

resource "azurerm_public_ip" "vm_public_ips" {
  for_each            = var.vms
  name                = "${each.key}-public-ip"
  location            = azurerm_resource_group.monitoring.location
  resource_group_name = azurerm_resource_group.monitoring.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_security_group" "vm_nsgs" {
  for_each            = var.vms
  name                = "${each.key}-nsg"
  location            = azurerm_resource_group.monitoring.location
  resource_group_name = azurerm_resource_group.monitoring.name
  tags                = var.tags

  security_rule {
    name                       = each.value.os == "Linux" ? "allow-ssh" : "allow-rdp"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = each.value.os == "Linux" ? "22" : "3389"
    source_address_prefix      = var.admin_source_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "vm_nics" {
  for_each            = var.vms
  name                = "${each.key}-nic"
  location            = azurerm_resource_group.monitoring.location
  resource_group_name = azurerm_resource_group.monitoring.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm_public_ips[each.key].id
  }
}

resource "azurerm_network_interface_security_group_association" "vm_nsg_associations" {
  for_each                  = var.vms
  network_interface_id      = azurerm_network_interface.vm_nics[each.key].id
  network_security_group_id = azurerm_network_security_group.vm_nsgs[each.key].id
}

resource "azurerm_linux_virtual_machine" "linux_vms" {
  for_each            = local.linux_vms
  name                = each.key
  computer_name       = each.key
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = azurerm_resource_group.monitoring.location
  size                = each.value.size
  admin_username      = var.admin_username
  network_interface_ids = [
    azurerm_network_interface.vm_nics[each.key].id,
  ]
  disable_password_authentication = false
  admin_password                  = var.admin_password
  tags                            = var.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  lifecycle {
    precondition {
      condition     = var.admin_password != null && length(var.admin_password) >= 12
      error_message = "Provide admin_password with at least 12 characters for VM access."
    }
  }
}

resource "azurerm_windows_virtual_machine" "windows_vms" {
  for_each            = local.windows_vms
  name                = each.key
  computer_name       = each.key
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = azurerm_resource_group.monitoring.location
  size                = each.value.size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  network_interface_ids = [
    azurerm_network_interface.vm_nics[each.key].id,
  ]
  automatic_updates_enabled = true
  patch_mode                = "AutomaticByPlatform"
  tags                      = var.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

  lifecycle {
    precondition {
      condition     = var.admin_password != null && length(var.admin_password) >= 12
      error_message = "Provide admin_password with at least 12 characters for VM access."
    }
  }
}
