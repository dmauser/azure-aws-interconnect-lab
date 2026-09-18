##############################################################################
# Latency probe - measuring the interconnect from the region that owns it
#
# The lab's headline number was always measured from the spoke VM in East US 2,
# because this subscription cannot build a VM in East US. That measurement
# includes the eastus2 -> eastus hop imposed by the forced region split, so it
# overstates the interconnect's latency by roughly a factor of two.
#
# This file adds a second vantage point *inside the hub*, beside the
# ExpressRoute gateway, so the two can be compared directly.
#
#   snet-<prefix>-probe (hub, East US)
#     -> ci-<prefix>-probe   Azure Container Instances, private IP only
#                            runs prober.py: ICMP echo + TCP connect RTT
#                            POSTs samples across the hub<->spoke peering to...
#
#   vm-<prefix>-azure (spoke, East US 2)
#     -> collector.py        ingests, aggregates, serves the dashboard on
#                            var.probe_dashboard_port
#     -> prober.py           second vantage point, probing the same target
#
# Why Container Instances and not something with its own ingress:
#
#   * Container Apps cannot be created in East US on this subscription. The
#     environment build runs for ~6 minutes and then fails with HTTP 400
#     AKSCapacityHeavyUsage - ACA is AKS-backed, so it inherits exactly the same
#     capacity wall that blocks VMs.
#   * App Service reports a quota of 0 VMs in East US for P0v3, B1 and S1.
#   * ACI injected into a VNet works, but only ever gets a private IP, so it
#     cannot host the dashboard itself.
#
# Hence the split: probe in the hub where the latency is, dashboard on the VM
# where the public IP already exists.
#
# The transport layer is untouched by everything here.
##############################################################################

locals {
  probe_enabled = var.enable_latency_probe

  # The collector listens on the VM's private address. The hub<->spoke peering
  # already carries this traffic; no new peering or route is required.
  probe_collector_url = "http://${azurerm_network_interface.vm.private_ip_address}:${var.probe_dashboard_port}"

  probe_files = {
    "prober.py"    = filebase64("${path.module}/probe/prober.py")
    "collector.py" = filebase64("${path.module}/probe/collector.py")
  }
}

##############################################################################
# Probe subnet - hub VNet, delegated to Container Instances
#
# Delegation is mandatory: ACI refuses to join an undelegated subnet, and a
# delegated subnet cannot host anything else.
##############################################################################

resource "azurerm_subnet" "probe" {
  count = local.probe_enabled ? 1 : 0

  name                 = "snet-${var.prefix}-probe"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.azure_probe_subnet_cidr]

  delegation {
    name = "aci-delegation"

    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

##############################################################################
# The eastus prober
#
# restart_policy = "Always" because a latency probe that stops is worthless.
# The image comes from MCR, not Docker Hub: ACI in this subscription fails to
# pull from index.docker.io with RegistryErrorResponse.
#
# The prober source is mounted from a secret volume rather than passed on the
# command line - a base64 script large enough to matter breaks the az CLI
# argument handling, and a mounted file is far easier to read back when
# debugging.
##############################################################################

resource "azurerm_container_group" "probe" {
  count = local.probe_enabled ? 1 : 0

  name                = "ci-${var.prefix}-probe"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.azure_hub_location
  os_type             = "Linux"
  restart_policy      = "Always"
  ip_address_type     = "Private"
  subnet_ids          = [azurerm_subnet.probe[0].id]
  tags                = local.tags

  container {
    name   = "prober"
    image  = var.probe_image
    cpu    = var.probe_cpu
    memory = var.probe_memory_gb

    commands = ["python3", "/opt/probe/prober.py"]

    # Container Instances rejects a group whose ipAddress has no ports:
    #
    #   400 MissingIpAddressPorts: The ports in the 'ipAddress' of container
    #   group 'ci-<prefix>-probe' cannot be empty.
    #
    # Nothing in this group listens. The prober is outbound-only - it probes AWS
    # and POSTs results to the collector on the spoke VM. The port is declared
    # purely to satisfy that validation, and connections to it are refused.
    # Liveness is observed through the collector (samples arriving tagged with
    # the hub vantage) or `az container logs`, not through this port.
    ports {
      port     = var.probe_dashboard_port
      protocol = "TCP"
    }

    environment_variables = {
      PROBE_VANTAGE          = "azure-hub-${var.azure_hub_location}"
      PROBE_REGION           = var.azure_hub_location
      PROBE_TARGET           = aws_instance.vm.private_ip
      PROBE_TARGET_LABEL     = "aws-${var.aws_region}"
      PROBE_TCP_PORT         = tostring(var.probe_tcp_port)
      PROBE_INTERVAL_SECONDS = tostring(var.probe_interval_seconds)
      PROBE_COLLECTOR_URL    = local.probe_collector_url
    }

    volume {
      name       = "probe-src"
      mount_path = "/opt/probe"
      read_only  = true
      secret     = local.probe_files
    }
  }

  # The container starts probing immediately, so the collector and the
  # ExpressRoute path both need to exist first. Without the peering the POST
  # back to the spoke has nowhere to go.
  depends_on = [
    azurerm_linux_virtual_machine.vm,
    azurerm_virtual_network_peering.hub_to_spoke,
    azurerm_virtual_network_peering.spoke_to_hub,
  ]
}
