##############################################################################
# Observability
#
#   VNet flow logs (+ Traffic Analytics) on the spoke VNet
#   Network Watcher Connection Monitor: Azure VM -> AWS VM private IP
#
# Both are optional. The Log Analytics workspace and Connection Monitor are
# gated on var.enable_observability; the flow logs are gated on that AND on
# var.enable_flow_logs, which defaults to false because flow logs require
# storage shared-key access (see the locals block below).
#
# Scope note: flow logs are attached to the SPOKE VNet only. Flow logs record
# NIC-level flows, and the ExpressRoute gateway is a platform-managed VMSS whose
# interfaces are not exposed, so a hub flow log would capture nothing useful
# while adding a second Network Watcher region and more storage.
##############################################################################

locals {
  observability = var.enable_observability ? 1 : 0

  # Flow logs are gated separately from the rest of observability. They write to
  # blob storage using SHARED KEY authentication, which many subscriptions deny
  # via Azure Policy ("Storage accounts should prevent shared key access").
  #
  # In this tenant the policy uses a MODIFY effect rather than Deny: the storage
  # account is created successfully but with allowSharedKeyAccess rewritten to
  # false, and the failure only surfaces later as
  #
  #   403 KeyBasedAuthenticationNotPermitted: Key based authentication is not
  #   permitted on this storage account.
  #
  # The SecurityControl=Ignore tag on azurerm_storage_account.flowlogs exempts
  # the account from that policy, which is what makes flow logs viable here. On
  # a tenant that enforces the same control with a Deny effect, or that does not
  # honour that tag, this must stay false. The Log Analytics workspace and the
  # Connection Monitor are unaffected either way.
  flow_logs = var.enable_observability && var.enable_flow_logs ? 1 : 0
}

# Azure auto-creates one Network Watcher per region in NetworkWatcherRG.
data "azurerm_network_watcher" "spoke" {
  count               = local.observability
  name                = "NetworkWatcher_${var.azure_location}"
  resource_group_name = "NetworkWatcherRG"
}

resource "random_string" "storage_suffix" {
  count   = local.flow_logs
  length  = 8
  lower   = true
  upper   = false
  numeric = true
  special = false
}

##############################################################################
# Sinks
##############################################################################

# Flow logs require a v2 storage account in the same region as the flow log.
resource "azurerm_storage_account" "flowlogs" {
  count                           = local.flow_logs
  name                            = "st${var.prefix}${random_string.storage_suffix[0].result}"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = var.azure_location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  # Flow logs write to blob storage with SHARED KEY auth, and there is no
  # Entra-only alternative. Asserted explicitly rather than left to the provider
  # default so that `terraform plan` reports drift if the policy exemption below
  # ever stops applying.
  shared_access_key_enabled = true

  # SecurityControl=Ignore exempts the account from the tenant policy that would
  # otherwise silently rewrite allowSharedKeyAccess to false. The policy uses a
  # MODIFY effect, not Deny, so without this tag the create still SUCCEEDS and
  # only the flow log writer fails later with
  # 403 KeyBasedAuthenticationNotPermitted -- which is why the create exit code
  # cannot be trusted here and the property must be read back.
  #
  # Verified empirically in subscription DMAUSER-FDPO (tenant 16b3c013):
  #   untagged  + --allow-shared-key-access true -> reads back false
  #   tagged    + --allow-shared-key-access true -> reads back true
  #
  # This tag is a Microsoft-internal convention, not a documented Azure feature;
  # it has no effect in tenants whose policies do not look for it.
  tags = merge(local.tags, { SecurityControl = "Ignore" })
}

resource "azurerm_log_analytics_workspace" "lab" {
  count               = local.observability
  name                = "law-${var.prefix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.azure_location
  sku                 = "PerGB2018"

  # 30 days is the minimum billable retention; the first 5 GB/month is free.
  retention_in_days = 30
  tags              = local.tags
}

##############################################################################
# VNet flow logs
##############################################################################

resource "azurerm_network_watcher_flow_log" "spoke" {
  count = local.flow_logs

  name                 = "fl-${var.prefix}-spoke"
  network_watcher_name = data.azurerm_network_watcher.spoke[0].name
  resource_group_name  = data.azurerm_network_watcher.spoke[0].resource_group_name
  location             = var.azure_location

  # VNet-scoped flow logs. NSG flow logs are retired; targeting the VNet
  # captures every NIC in it, including ones added later.
  target_resource_id = azurerm_virtual_network.lab.id
  storage_account_id = azurerm_storage_account.flowlogs[0].id
  enabled            = true
  version            = 2

  retention_policy {
    enabled = true
    days    = var.flow_log_retention_days
  }

  dynamic "traffic_analytics" {
    for_each = var.enable_traffic_analytics ? [1] : []
    content {
      enabled               = true
      workspace_id          = azurerm_log_analytics_workspace.lab[0].workspace_id
      workspace_region      = azurerm_log_analytics_workspace.lab[0].location
      workspace_resource_id = azurerm_log_analytics_workspace.lab[0].id

      # 60 minutes is the cheaper of the two supported intervals (vs 10).
      interval_in_minutes = 60
    }
  }

  tags = local.tags
}

##############################################################################
# Connection Monitor
#
# The Azure VM is the probing source, so it needs the Network Watcher agent.
# The AWS VM is referenced as a bare private address ("external address"
# endpoint), which needs no agent and no Azure Arc onboarding - the probe
# simply has to traverse the interconnect to reach it.
##############################################################################

resource "azurerm_virtual_machine_extension" "network_watcher" {
  count = local.observability

  name                       = "NetworkWatcherAgentLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.vm.id
  publisher                  = "Microsoft.Azure.NetworkWatcher"
  type                       = "NetworkWatcherAgentLinux"
  type_handler_version       = "1.4"
  auto_upgrade_minor_version = true
  tags                       = local.tags
}

resource "azurerm_network_connection_monitor" "cross_cloud" {
  count = local.observability

  name               = "cm-${var.prefix}-azure-to-aws"
  network_watcher_id = data.azurerm_network_watcher.spoke[0].id
  location           = var.azure_location
  tags               = local.tags

  endpoint {
    name                 = "azure-vm"
    target_resource_id   = azurerm_linux_virtual_machine.vm.id
    target_resource_type = "AzureVM"
  }

  endpoint {
    name    = "aws-vm-private"
    address = aws_instance.vm.private_ip
  }

  # ICMP with traceroute: shows the hop-by-hop path across the interconnect and
  # catches asymmetric routing, which is the failure mode a plain ping hides.
  test_configuration {
    name                      = "icmp"
    protocol                  = "Icmp"
    test_frequency_in_seconds = 60

    icmp_configuration {
      trace_route_enabled = true
    }

    success_threshold {
      checks_failed_percent = 10
      round_trip_time_ms    = 100
    }
  }

  # TCP proves a real session establishes, not just that ICMP is permitted.
  test_configuration {
    name                      = "tcp-22"
    protocol                  = "Tcp"
    test_frequency_in_seconds = 60

    tcp_configuration {
      port                      = 22
      trace_route_enabled       = true
      destination_port_behavior = "None"
    }

    success_threshold {
      checks_failed_percent = 10
      round_trip_time_ms    = 100
    }
  }

  test_group {
    name                     = "azure-to-aws"
    source_endpoints         = ["azure-vm"]
    destination_endpoints    = ["aws-vm-private"]
    test_configuration_names = ["icmp", "tcp-22"]
  }

  output_workspace_resource_ids = [azurerm_log_analytics_workspace.lab[0].id]

  # The agent must be present before the monitor starts probing.
  depends_on = [azurerm_virtual_machine_extension.network_watcher]

  lifecycle {
    # Recreate rather than update whenever the VM is replaced.
    #
    # azurerm cannot update this resource in place once the source VM's ID
    # changes -- it fails the apply with "Provider produced inconsistent final
    # plan ... planned set element ... does not correlate with any element in
    # actual" on .endpoint. That is a provider bug, but it is reached every time
    # the VM is rebuilt, which the probe's cloud-init makes routine.
    replace_triggered_by = [azurerm_linux_virtual_machine.vm]
  }
}

