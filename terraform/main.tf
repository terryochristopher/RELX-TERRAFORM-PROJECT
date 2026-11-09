resource "aws_vpc" "main" {
  cidr_block       = var.cidr_block
  instance_tenancy = "default"
  enable_dns_support = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project-name}-${var.environment}-vpc"
    
  }
}

resource "aws_internet_gateway" "relx-gateway" {
    vpc_id = aws_vpc.main.id
    tags = {
        Name = "${var.project-name}-${var.environment}-gw"
    }
  
}

resource "aws_subnet" "relx-publicsubnet" {
  vpc_id     = aws_vpc.main.id
  cidr_block = var.subnet-cidr

  tags = {
    Name = "${var.project-name}-${var.environment}-pubsubnet"
  }
}

resource "aws_subnet" "relx-privatesubnet" {
  vpc_id     = aws_vpc.main.id
  cidr_block = var.privatesubnet-cidr

  tags = {
    Name = "${var.project-name}-${var.environment}-prisubnet"
  }
}

resource "aws_route_table" "relx-publicroute" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.relx-gateway.id
  }

  tags = {
    Name = "${var.project-name}-${var.environment}-pubroute"
  }
}

resource "aws_route_table_association" "pub-association" {
  subnet_id = aws_subnet.relx-publicsubnet.id
  route_table_id = aws_route_table.relx-publicroute.id
}

resource "aws_route_table" "relx-privateroute" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project-name}-${var.environment}-priroute"
  }
}
resource "aws_route_table_association" "pri-association" {
  subnet_id = aws_subnet.relx-privatesubnet.id
  route_table_id = aws_route_table.relx-privateroute.id
}


resource "aws_eip" "relx-eip" { 
    count = 1
    domain = "vpc"
    depends_on = [aws_internet_gateway.relx-gateway]
    tags = {
    Name = "${var.project-name}-${var.environment}-eip"
    }
}

resource "aws_nat_gateway" "relx-natgw" {
    allocation_id = aws_eip.relx-eip[0].id
    subnet_id = aws_subnet.relx-publicsubnet.id
    depends_on = [aws_internet_gateway.relx-gateway] 
}

#NETWORKING COMPONENTS
resource "aws_security_group" "relx-bastion" {
    name = "${var.project-name}-${var.environment}-relxbastion"
    vpc_id = aws_vpc.main.id
    ingress { 
        description = "SSH from approved admin IP"
        from_port = 22
        to_port = 22
        protocol = "tcp"
        cidr_blocks = [var.admin_cidr] 
    }
    egress { 
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"] 
    }
}
resource "aws_security_group" "relx-alb" {
  name = "${var.project-name}-${var.environment}-relxalb"
    vpc_id = aws_vpc.main.id
    ingress { 
        description = "Public HTTP"
        from_port = 80
        to_port = 80
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"] 
    }
    egress { 
        description = "HTTP to VPC"
        from_port = 80
        to_port = 80
        protocol = "tcp"
        cidr_blocks = [var.cidr_block] 
    }
}
resource "aws_security_group" "web" {
  name = "${var.project-name}-${var.environment}-relxweb"
  vpc_id = aws_vpc.main.id
  ingress { 
    description = "HTTP only from ALB"
    from_port = 80
    to_port = 80
    protocol = "tcp"
    security_groups = [aws_security_group.relx-alb.id] 
  }
  ingress {
    description = "HTTP test from bastion"
    from_port = 80
    to_port = 80
    protocol = "tcp"
    security_groups = [aws_security_group.relx-bastion.id] 
  }
  ingress { 
    description = "SSH from bastion"
    from_port = 22
    to_port = 22
    protocol = "tcp"
    security_groups = [aws_security_group.relx-bastion.id] 
  }
  egress {
    description = "Outbound packages and AWS APIs"
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"] 
  }
}




