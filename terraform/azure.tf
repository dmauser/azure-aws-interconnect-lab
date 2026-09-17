##############################################################################
# Azure side - hub/spoke
#
#   hub VNet   (var.azure_hub_location, East US)
#     GatewaySubnet -> ExpressRoute gateway -> ExpressRoute connection to the
#     EXISTING Azure Multicloud Interconnect circuit (ER-AWS-Lab).
#
#   spoke VNet (var.azure_location, East US 2)
#     snet-vm -> Linux VM
#
#   peered both ways with gateway transit, so the spoke reaches AWS through the
#   hub's ExpressRoute gateway.
#
# Why two VNets instead of one:
#   * ER-AWS-Lab is a MultiCloud-tier circuit, which the platform treats as a
#     LOCAL circuit. A Local circuit only attaches to the single designated
#     Azure region for its peering location ("useast" -> East US). Connecting a
#     gateway in any other region fails with InvalidParameter, and MultiCloud
#     tier has no Standard/Premium upgrade path.
#   * The lab subscription could not deploy VMs in East US (every VM SKU is
#     NotAvailableForSubscription at Location scope). Gateways are not VMs, so
#     the gateway is fine there - only the VM has to live elsewhere.
#
# The circuit itself is never created or destroyed here.
##############################################################################

resource "azurerm_resource_group" "lab" {
  name     = "rg-${var.prefix}-azure"
  location = var.azure_location
  tags     = local.tags
}

##############################################################################
# Hub VNet - ExpressRoute gateway only, no workloads
##############################################################################

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-${var.prefix}-hub"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.azure_hub_location
  address_space       = [var.azure_hub_vnet_cidr]
  tags                = local.tags
}

# Must be named exactly "GatewaySubnet" for Azure to place the gateway in it.
# Never attach an NSG or a 0.0.0.0/0 UDR to this subnet.
resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.azure_gateway_subnet_cidr]
}

##############################################################################
# Spoke VNet - the Linux VM
##############################################################################

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-${var.prefix}-spoke"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.azure_location
  address_space       = [var.azure_vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-vm"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.azure_vm_subnet_cidr]
}

##############################################################################
# Hub <-> spoke peering with gateway transit
#
# The spoke's prefix is advertised to AWS over ExpressRoute because the spoke
# uses the hub's gateway. use_remote_gateways is only valid once the gateway
# exists, hence the explicit depends_on.
##############################################################################

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "peer-hub-to-spoke"
  resource_group_name       = azurerm_resource_group.lab.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.lab.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "peer-spoke-to-hub"
  resource_group_name       = azurerm_resource_group.lab.name
  virtual_network_name      = azurerm_virtual_network.lab.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = true

  depends_on = [azurerm_virtual_network_gateway.ergw]
}

##############################################################################
# Network security group (workload subnet only)
##############################################################################

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-${var.prefix}-vm"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = local.tags

  security_rule {
    name                       = "AllowSshFromMyIp"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = local.my_cidr
    destination_address_prefix = "*"
  }

  # The interconnect test path: everything from the AWS VPC.
  security_rule {
    name                       = "AllowAllFromAwsVpc"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.aws_vpc_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

##############################################################################
# ExpressRoute gateway
##############################################################################

# ExpressRoute gateways get a platform-managed public IP. Supplying our own is
# rejected by the API, so no azurerm_public_ip resource exists here.
resource "azurerm_virtual_network_gateway" "ergw" {
  name                = "ergw-${var.prefix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.azure_hub_location

  type = "ExpressRoute"
  sku  = var.azure_ergw_sku
  tags = local.tags

  ip_configuration {
    name                          = "default"
    subnet_id                     = azurerm_subnet.gateway.id
    private_ip_address_allocation = "Dynamic"
  }

  # Creating an ExpressRoute gateway routinely takes 20-30 minutes.
  timeouts {
    create = "90m"
    update = "90m"
    delete = "60m"
  }
}

# Azure Multicloud Interconnect preview allows exactly ONE gateway connection
# per interconnect. If this fails with a conflict, another VNet is already
# attached to ER-AWS-Lab.
resource "azurerm_virtual_network_gateway_connection" "ergw" {
  count = var.create_interconnect ? 1 : 0

  name                = "conn-${var.prefix}-to-aws"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.azure_hub_location
  tags                = local.tags

  type                       = "ExpressRoute"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.ergw.id
  express_route_circuit_id   = local.circuit_id
  routing_weight             = 0

  timeouts {
    create = "60m"
    delete = "60m"
  }
}

##############################################################################
# Linux VM
##############################################################################

resource "azurerm_public_ip" "vm" {
  name                = "pip-${var.prefix}-vm"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags

  lifecycle {
    # Azure injects ip_tags = { FirstPartyUsage = "/Unprivileged" } on this
    # subscription. Terraform reads it as drift and tries to remove it, which
    # forces replacement on every plan -- and the destroy then fails because the
    # NIC still holds the address.
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_network_interface" "vm" {
  name                = "nic-${var.prefix}-vm"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                = "vm-${var.prefix}-azure"
  computer_name       = "az-lab-vm"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  size                = var.azure_vm_size
  admin_username      = var.azure_vm_admin_username
  tags                = local.tags

  network_interface_ids = [azurerm_network_interface.vm.id]

  admin_ssh_key {
    username   = var.azure_vm_admin_username
    public_key = local.ssh_public_key
  }

  disable_password_authentication = true

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS" # cheapest disk tier
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/cloudinit/azure-vm.yaml.tftpl", {
    mtu = var.mtu
  }))
}

# Cost control: the VM is a rounding error next to the gateway, but free to add.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "vm" {
  count = var.azure_auto_shutdown_time == null ? 0 : 1

  virtual_machine_id    = azurerm_linux_virtual_machine.vm.id
  location              = azurerm_resource_group.lab.location
  enabled               = true
  daily_recurrence_time = var.azure_auto_shutdown_time
  timezone              = var.azure_auto_shutdown_timezone
  tags                  = local.tags

  notification_settings {
    enabled = false
  }
}
