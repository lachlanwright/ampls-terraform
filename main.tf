terraform {
  required_version = ">= 1.0.0"
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "this" {
  name     = "ampls-rg"
  location = "australiaeast"
}

# --------------------------------------------------------------------------------------------------
# Network
# --------------------------------------------------------------------------------------------------

data http source_ip {
  url = "https://ifconfig.me"
}

resource "azurerm_virtual_network" "net" {
  name                = "vn-amplsdemo"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = ["10.0.0.0/24"]
}

resource "azurerm_subnet" "net_default" {
  name                 = "default"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.net.name
  address_prefixes     = ["10.0.0.0/28"]
}

resource "azurerm_subnet" "ampls_private_endpoints" {
  name                 = "ampls-private-endpoints"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.net.name
  address_prefixes     = ["10.0.0.16/28"]

  enforce_private_link_endpoint_network_policies = true
  enforce_private_link_service_network_policies  = true
}

resource "azurerm_network_security_group" "net_default" {
  name                = "nsg-net-default"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  security_rule {
    name                       = "AllowRemoteAccess"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = data.http.source_ip.body
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "net_default" {
  subnet_id                 = azurerm_subnet.net_default.id
  network_security_group_id = azurerm_network_security_group.net_default.id
}

# --------------------------------------------------------------------------------------------------
# Log Analytics Workspace
# --------------------------------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "this" {
  name                = "law-amplsdemo"
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
  name                = "amplsdemo"
  resource_group_name = azurerm_resource_group.this.name
  deployment_mode     = "Incremental"
  parameters_content  = jsonencode({
    "private_link_scope_name" = {
      value = "ps-amplsdemo"
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
          "type": "String"
        },
        "workspace_name": {
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
  name                = "pe-amplsdemo"
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
  ttl                 = 3600
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 7)]
}

resource "azurerm_private_dns_a_record" "monitor_global" {
  name                = "global.in.ai"
  zone_name           = azurerm_private_dns_zone.monitor.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 3600
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 8)]
}

resource "azurerm_private_dns_a_record" "monitor_profiler" {
  name                = "profiler"
  zone_name           = azurerm_private_dns_zone.monitor.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 3600
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 9)]
}

resource "azurerm_private_dns_a_record" "monitor_live" {
  name                = "live"
  zone_name           = azurerm_private_dns_zone.monitor.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 3600
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 10)]
}

resource "azurerm_private_dns_a_record" "monitor_snapshot" {
  name                = "snapshot"
  zone_name           = azurerm_private_dns_zone.monitor.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 3600
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 11)]
}

resource "azurerm_private_dns_zone_virtual_network_link" "monitor-net" {
  name                  = "pl-monitor-net"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.monitor.name
  virtual_network_id    = azurerm_virtual_network.net.id
}

resource "azurerm_private_dns_zone" "oms" {
  name                = "privatelink.oms.opinsights.azure.com"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_a_record" "oms_law_id" {
  name                = azurerm_log_analytics_workspace.this.workspace_id
  zone_name           = azurerm_private_dns_zone.oms.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 3600
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 4)]
}

resource "azurerm_private_dns_zone_virtual_network_link" "oms-net" {
  name                  = "pl-oms-net"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.oms.name
  virtual_network_id    = azurerm_virtual_network.net.id
}

resource "azurerm_private_dns_zone" "ods" {
  name                = "privatelink.ods.opinsights.azure.com"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_a_record" "ods_law_id" {
  name                = azurerm_log_analytics_workspace.this.workspace_id
  zone_name           = azurerm_private_dns_zone.ods.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 3600
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 5)]
}

resource "azurerm_private_dns_zone_virtual_network_link" "ods-net" {
  name                  = "pl-ods-net"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.ods.name
  virtual_network_id    = azurerm_virtual_network.net.id
}

resource "azurerm_private_dns_zone" "agentsvc" {
  name                = "privatelink.agentsvc.azure-automation.net"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_a_record" "agentsvc_law_id" {
  name                = azurerm_log_analytics_workspace.this.workspace_id
  zone_name           = azurerm_private_dns_zone.agentsvc.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 3600
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 6)]
}

resource "azurerm_private_dns_zone_virtual_network_link" "agentsvc-net" {
  name                  = "pl-agentsvc-net"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.agentsvc.name
  virtual_network_id    = azurerm_virtual_network.net.id
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_a_record" "blob_scadvisorcontentpld" {
  name                = "scadvisorcontentpl"
  zone_name           = azurerm_private_dns_zone.blob.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 3600
  records             = [cidrhost(azurerm_subnet.ampls_private_endpoints.address_prefixes[0], 12)]
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob-net" {
  name                  = "pl-blob-net"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.net.id
}

# --------------------------------------------------------------------------------------------------
# Virtual Machine
# --------------------------------------------------------------------------------------------------

resource "azurerm_network_interface" "demovm" {
  name                = "nic-amplsdemo"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "main"
    subnet_id                     = azurerm_subnet.net_default.id
    public_ip_address_id          = azurerm_public_ip.demovm.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_public_ip" "demovm" {
  name                = "pip-amplsdemo"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
}

resource "random_password" "demovm" {
  length           = 16
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
  special          = true
  override_special = "#%^&*"
}

resource "azurerm_windows_virtual_machine" "demovm" {
  name                = "vmamplsdemo"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  size                = "Standard_D2s_v3"
  admin_username      = "captain"
  admin_password      = random_password.demovm.result
  network_interface_ids = [
    azurerm_network_interface.demovm.id,
  ]

  os_disk {
    name                 = "vmamplsdemo-osdisk"
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

output vm_public_ip {
  value       = azurerm_public_ip.demovm.ip_address
}

output username {
  value       = azurerm_windows_virtual_machine.demovm.admin_username
}

output password {
  value       = nonsensitive(random_password.demovm.result)
}

output allowed_source_address {
  value       = data.http.source_ip.body
}
