provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "this" {
  name     = "ampls_rg"
  location = "australiaeast"
}

# --------------------------------------------------------------------------------------------------
# Network
# --------------------------------------------------------------------------------------------------
resource "azurerm_virtual_network" "hub" {
  name                = "ampls_hub"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = ["10.0.0.0/24"]
  dns_servers         = ["10.0.0.4"]
}

resource "azurerm_subnet" "hub_default" {
  name                 = "default"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.0.0.0/28"]
}

resource "azurerm_subnet" "ampls_private_endpoints" {
  name                 = "ampls_private_endpoints"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.0.0.16/28"]

  enforce_private_link_endpoint_network_policies = true
  enforce_private_link_service_network_policies  = true
}

resource "azurerm_network_security_group" "hub_default" {
  name                = "nsg_hub_default"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  security_rule {
    name                       = "AllowRemoteAccess"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefixes    = ["119.17.157.18"]
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowDNS"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["53"]
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "ampls_private_endpoints" {
  name                = "nsg_hub_ampls_private_endpoints"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_subnet_network_security_group_association" "hub_default" {
  subnet_id                 = azurerm_subnet.hub_default.id
  network_security_group_id = azurerm_network_security_group.hub_default.id
}

resource "azurerm_subnet_network_security_group_association" "ampls_private_endpoints" {
  subnet_id                 = azurerm_subnet.ampls_private_endpoints.id
  network_security_group_id = azurerm_network_security_group.ampls_private_endpoints.id
}

resource "azurerm_virtual_network" "spoke" {
  name                = "ampls_spoke"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = ["10.0.1.0/24"]
  dns_servers         = ["10.0.0.4"]
}

resource "azurerm_subnet" "spoke_default" {
  name                 = "default"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = ["10.0.1.0/28"]
}

resource "azurerm_network_security_group" "spoke_default" {
  name                = "nsg_spoke_default"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  security_rule {
    name                       = "AllowRemoteAccess"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefixes    = ["119.17.157.18"]
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "spoke_default" {
  subnet_id                 = azurerm_subnet.spoke_default.id
  network_security_group_id = azurerm_network_security_group.spoke_default.id
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "hub2spoke"
  resource_group_name       = azurerm_resource_group.this.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.spoke.id
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "spoke2hub"
  resource_group_name       = azurerm_resource_group.this.name
  virtual_network_name      = azurerm_virtual_network.spoke.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
}

# --------------------------------------------------------------------------------------------------
# LAW
# --------------------------------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "this" {
  name                = "ampls-law"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  internet_ingestion_enabled = true
  internet_query_enabled     = true
}

# --------------------------------------------------------------------------------------------------
# Private Link Scope
# --------------------------------------------------------------------------------------------------
resource "azurerm_resource_group_template_deployment" "this" {
  name                = "ampls"
  resource_group_name = azurerm_resource_group.this.name
  deployment_mode     = "Incremental"
  parameters_content  = jsonencode({
    "private_link_scope_name" = {
      value = "ampls_private_scope"
    }
    "workspace_name" = {
      value = azurerm_log_analytics_workspace.this.name
    }
  })
  template_content = <<-EOT
    {
      "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
      "contentVersion": "1.0.0.0",
      "parameters": {
        "private_link_scope_name": {
          "defaultValue": "my-scope",
          "type": "String"
        },
        "workspace_name": {
          "defaultValue": "my-workspace",
          "type": "String"
        }
      },
      "variables": {},
      "resources": [
        {
          "type": "microsoft.insights/privatelinkscopes",
          "apiVersion": "2019-10-17-preview",
          "name": "[parameters('private_link_scope_name')]",
          "location": "global",
          "properties": {}
        },
        {
          "type": "microsoft.insights/privatelinkscopes/scopedresources",
          "apiVersion": "2019-10-17-preview",
          "name": "[concat(parameters('private_link_scope_name'), '/', concat(parameters('workspace_name'), '-connection'))]",
          "dependsOn": [
            "[resourceId('microsoft.insights/privatelinkscopes', parameters('private_link_scope_name'))]"
          ],
          "properties": {
            "linkedResourceId": "[resourceId('microsoft.operationalinsights/workspaces', parameters('workspace_name'))]"
          }
        }
      ],
      "outputs": {
        "resourceID": {
          "type": "String",
          "value": "[resourceId('microsoft.insights/privatelinkscopes', parameters('private_link_scope_name'))]"
        }
      }
    }
  EOT
}

# --------------------------------------------------------------------------------------------------
# Private Endpoint
# --------------------------------------------------------------------------------------------------
resource "azurerm_private_endpoint" "ampls" {
  name                = "ampls_private_endpoint"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.ampls_private_endpoints.id

  private_service_connection {
    name                           = "ampls-privateserviceconnection"
    private_connection_resource_id = jsondecode(azurerm_resource_group_template_deployment.this.output_content).resourceID.value
    is_manual_connection           = false
    subresource_names              = ["azuremonitor"]
  }

  private_dns_zone_group {
    name = "ampls"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.monitor.id,
      azurerm_private_dns_zone.oms.id,
      azurerm_private_dns_zone.ods.id,
      azurerm_private_dns_zone.agentsvc.id,
      azurerm_private_dns_zone.blob.id
    ]
  }
}

# --------------------------------------------------------------------------------------------------
# Private DNS Zones
# --------------------------------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "monitor" {
  name                = "privatelink.monitor.azure.com"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_a_record" "monitor_api" {
  name                = "api"
  zone_name           = azurerm_private_dns_zone.monitor.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 10
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 7)]
}

resource "azurerm_private_dns_a_record" "monitor_global" {
  name                = "global.in.ai"
  zone_name           = azurerm_private_dns_zone.monitor.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 10
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 8)]
}

resource "azurerm_private_dns_a_record" "monitor_profiler" {
  name                = "profiler"
  zone_name           = azurerm_private_dns_zone.monitor.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 10
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 9)]
}

resource "azurerm_private_dns_a_record" "monitor_live" {
  name                = "live"
  zone_name           = azurerm_private_dns_zone.monitor.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 10
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 10)]
}

resource "azurerm_private_dns_a_record" "monitor_snapshot" {
  name                = "snapshot"
  zone_name           = azurerm_private_dns_zone.monitor.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 10
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 11)]
}

resource "azurerm_private_dns_zone_virtual_network_link" "monitor-hub" {
  name                  = "pl-monitor-hub"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.monitor.name
  virtual_network_id    = azurerm_virtual_network.hub.id
}

# NOTE: This is only required if there is no Windows Server providing DNS from the hub.
# resource "azurerm_private_dns_zone_virtual_network_link" "monitor-spoke" {
#   name                  = "pl-monitor-spoke"
#   resource_group_name   = azurerm_resource_group.this.name
#   private_dns_zone_name = azurerm_private_dns_zone.monitor.name
#   virtual_network_id    = azurerm_virtual_network.spoke.id
# }

resource "azurerm_private_dns_zone" "oms" {
  name                = "privatelink.oms.opinsights.azure.com"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_a_record" "oms_law_id" {
  name                = azurerm_log_analytics_workspace.this.workspace_id
  zone_name           = azurerm_private_dns_zone.oms.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 10
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 4)]
}

resource "azurerm_private_dns_zone_virtual_network_link" "oms-hub" {
  name                  = "pl-oms-hub"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.oms.name
  virtual_network_id    = azurerm_virtual_network.hub.id
}

# NOTE: This is only required if there is no Windows Server providing DNS from the hub.
# resource "azurerm_private_dns_zone_virtual_network_link" "oms-spoke" {
#   name                  = "pl-oms-spoke"
#   resource_group_name   = azurerm_resource_group.this.name
#   private_dns_zone_name = azurerm_private_dns_zone.oms.name
#   virtual_network_id    = azurerm_virtual_network.spoke.id
# }

resource "azurerm_private_dns_zone" "ods" {
  name                = "privatelink.ods.opinsights.azure.com"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_a_record" "ods_law_id" {
  name                = azurerm_log_analytics_workspace.this.workspace_id
  zone_name           = azurerm_private_dns_zone.ods.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 10
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 5)]
}

resource "azurerm_private_dns_zone_virtual_network_link" "ods-hub" {
  name                  = "pl-ods-hub"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.ods.name
  virtual_network_id    = azurerm_virtual_network.hub.id
}

# NOTE: This is only required if there is no Windows Server providing DNS from the hub.
# resource "azurerm_private_dns_zone_virtual_network_link" "ods-spoke" {
#   name                  = "pl-ods-spoke"
#   resource_group_name   = azurerm_resource_group.this.name
#   private_dns_zone_name = azurerm_private_dns_zone.ods.name
#   virtual_network_id    = azurerm_virtual_network.sopke.id
# }

resource "azurerm_private_dns_zone" "agentsvc" {
  name                = "privatelink.agentsvc.azure-automation.net"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_a_record" "agentsvc_law_id" {
  name                = azurerm_log_analytics_workspace.this.workspace_id
  zone_name           = azurerm_private_dns_zone.agentsvc.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 10
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 6)]
}

resource "azurerm_private_dns_zone_virtual_network_link" "agentsvc-hub" {
  name                  = "pl-agentsvc-hub"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.agentsvc.name
  virtual_network_id    = azurerm_virtual_network.hub.id
}

# NOTE: This is only required if there is no Windows Server providing DNS from the hub.
# resource "azurerm_private_dns_zone_virtual_network_link" "agentsvc-spoke" {
#   name                  = "pl-agentsvc-spoke"
#   resource_group_name   = azurerm_resource_group.this.name
#   private_dns_zone_name = azurerm_private_dns_zone.agentsvc.name
#   virtual_network_id    = azurerm_virtual_network.spoke.id
# }

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_a_record" "blob_scadvisorcontentpld" {
  name                = "scadvisorcontentpl"
  zone_name           = azurerm_private_dns_zone.blob.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 10
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 12)]
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob-hub" {
  name                  = "pl-blob-hub"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.hub.id
}

# NOTE: This is only required if there is no Windows Server providing DNS from the hub.
# resource "azurerm_private_dns_zone_virtual_network_link" "blob-spoke" {
#   name                  = "pl-blob-spoke"
#   resource_group_name   = azurerm_resource_group.this.name
#   private_dns_zone_name = azurerm_private_dns_zone.blob.name
#   virtual_network_id    = azurerm_virtual_network.spoke.id
# }

# --------------------------------------------------------------------------------------------------
# Hub VM
# --------------------------------------------------------------------------------------------------
resource "azurerm_network_interface" "hubvm" {
  name                = "nic_hubvm"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "main"
    subnet_id                     = azurerm_subnet.hub_default.id
    public_ip_address_id          = azurerm_public_ip.hubvm.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.4"
  }
}

resource "azurerm_public_ip" "hubvm" {
  name                = "pip_hubvm"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
}

resource "random_password" "hubvm" {
  length           = 16
  special          = true
  override_special = "#%^&*"
}

resource "azurerm_windows_virtual_machine" "hubvm" {
  name                = "amplshubvm"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  size                = "Standard_D2s_v3"
  admin_username      = "captain"
  admin_password      = random_password.hubvm.result
  network_interface_ids = [
    azurerm_network_interface.hubvm.id,
  ]

  os_disk {
    name                 = "amplshubvm_osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2016-Datacenter"
    version   = "latest"
  }
}

# --------------------------------------------------------------------------------------------------
# Spoke VM
# --------------------------------------------------------------------------------------------------
resource "azurerm_network_interface" "spokevm" {
  name                = "nic_spokevm"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "main"
    subnet_id                     = azurerm_subnet.spoke_default.id
    public_ip_address_id          = azurerm_public_ip.spokevm.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_public_ip" "spokevm" {
  name                = "pip_spokevm"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
}

resource "random_password" "spokevm" {
  length           = 16
  special          = true
  override_special = "#%^&*"
}

resource "azurerm_windows_virtual_machine" "spokevm" {
  name                = "amplsspokevm"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  size                = "Standard_D2s_v3"
  admin_username      = "captain"
  admin_password      = random_password.spokevm.result
  network_interface_ids = [
    azurerm_network_interface.spokevm.id,
  ]

  os_disk {
    name                 = "amplsspokevm_osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2016-Datacenter"
    version   = "latest"
  }
}

# --------------------------------------------------------------------------------------------------
# Outputs
# --------------------------------------------------------------------------------------------------
# output "ampls_resource_id" {
#   value       = jsondecode(azurerm_resource_group_template_deployment.this.output_content).resourceID.value
# }

# output "hub_subnets" {
#   value       = azurerm_virtual_network.hub.subnet
# }

output "username" {
  value       = "captain"
}

output "hub_pip" {
  value       = azurerm_public_ip.hubvm.ip_address
}

output "hub_password" {
  # value       = nonsensitive(random_password.windows.result)
  value       = random_password.hubvm.result
}

output "spoke_pip" {
  value       = azurerm_public_ip.spokevm.ip_address
}

output "spoke_password" {
  # value       = nonsensitive(random_password.windows.result)
  value       = random_password.spokevm.result
}

output "workspace_id" {
  value = azurerm_log_analytics_workspace.this.workspace_id
}

# data "azurerm_private_endpoint_connection" "out" {
#   name                = "ampls_private_endpoint"
#   resource_group_name = azurerm_resource_group.this.name
# }

# output endpoint {
#   value       = data.azurerm_private_endpoint_connection.out
# }
