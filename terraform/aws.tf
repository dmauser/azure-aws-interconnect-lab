##############################################################################
# AWS side
#
# VPC -> Virtual Private Gateway -> association with the EXISTING Direct
# Connect Gateway that AWS Interconnect - multicloud connection mcc-EXAMPLE01
# is attached to.
#
# On AWS the interconnect attach point is ALWAYS a Direct Connect Gateway, so
# nothing here creates or touches the interconnect itself.
#
# VGW (not Transit Gateway) is deliberate: DXGW->VGW association is free,
# whereas a TGW attachment is ~USD 0.05/hr plus per-GB processing.
##############################################################################

resource "aws_vpc" "lab" {
  cidr_block           = var.aws_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "vpc-${var.prefix}" }
}

resource "aws_subnet" "vm" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.aws_subnet_cidr
  map_public_ip_on_launch = true

  tags = { Name = "snet-${var.prefix}-vm" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = { Name = "igw-${var.prefix}" }
}

resource "aws_route_table" "vm" {
  vpc_id = aws_vpc.lab.id

  # Default route for SSH access only. The Azure prefix arrives via BGP
  # propagation from the VGW, so it is deliberately NOT a static route.
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  # Pulls the Azure prefix (learned over the interconnect) into this route table.
  # Expressed inline rather than via aws_vpn_gateway_route_propagation, which
  # races against VGW attachment and fails with "couldn't find resource".
  propagating_vgws = [aws_vpn_gateway.lab.id]

  tags = { Name = "rt-${var.prefix}-vm" }
}

resource "aws_route_table_association" "vm" {
  subnet_id      = aws_subnet.vm.id
  route_table_id = aws_route_table.vm.id
}

##############################################################################
# Virtual Private Gateway + Direct Connect Gateway association
##############################################################################

resource "aws_vpn_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = { Name = "vgw-${var.prefix}" }
}

# Attaches this VPC to the interconnect's Direct Connect Gateway.
# VPC CIDRs are advertised automatically for VGW associations, so no
# allowed_prefixes block is required.
resource "aws_dx_gateway_association" "lab" {
  count = var.create_interconnect ? 1 : 0

  dx_gateway_id         = local.dxgw_id
  associated_gateway_id = aws_vpn_gateway.lab.id

  timeouts {
    create = "60m"
    delete = "60m"
  }
}

# Security group
##############################################################################

resource "aws_security_group" "vm" {
  # AWS rejects security group names that begin with "sg-".
  name        = "${var.prefix}-vm"
  description = "Lab VM: SSH from operator, everything from the Azure VNet"
  vpc_id      = aws_vpc.lab.id

  tags = { Name = "sg-${var.prefix}-vm" }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.vm.id
  description       = "SSH from operator public IP"
  cidr_ipv4         = local.my_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

# The interconnect test path: everything from the Azure hub and spoke VNets.
resource "aws_vpc_security_group_ingress_rule" "from_azure" {
  security_group_id = aws_security_group.vm.id
  description       = "All traffic from the Azure VNets over the interconnect"
  cidr_ipv4         = var.azure_supernet_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.vm.id
  description       = "Allow all egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

##############################################################################
# EC2 instance
##############################################################################

resource "aws_key_pair" "lab" {
  key_name   = "key-${var.prefix}"
  public_key = local.ssh_public_key
}

resource "aws_instance" "vm" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.aws_instance_type
  subnet_id              = aws_subnet.vm.id
  vpc_security_group_ids = [aws_security_group.vm.id]
  key_name               = aws_key_pair.lab.key_name

  user_data = templatefile("${path.module}/cloudinit/aws-vm.sh.tftpl", {
    mtu = var.mtu
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tags = { Name = "vm-${var.prefix}-aws" }

  lifecycle {
    # data.aws_ssm_parameter.al2023_arm64 resolves to whatever AMI Amazon
    # published most recently, so it moves on its own schedule. Without this,
    # an apply that was meant to change something else entirely destroys and
    # recreates the instance -- which changes its private IP, invalidates every
    # latency baseline collected so far, and silently rewrites the address the
    # probes and the docs both refer to.
    #
    # A fresh deployment still gets the current AMI; only an existing one is
    # held steady. Taint the instance deliberately to pick up a newer image.
    ignore_changes = [ami]
  }
}
