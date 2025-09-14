provider "aws" {
  region = "ap-southeast-1"
}

# VPC with private subnets (no public exposure for DB)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "lms-vpc"
  cidr = var.vpc_cidr
  tags = merge(local.common_tags, {
    Name = "lms-vpc"
  })

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway   = false #  DB doesn’t need outbound internet
  enable_dns_hostnames = true
  enable_dns_support   = true
}

# Security group for RDS (allow EC2 access only)
# resource "aws_security_group" "rds" {
#   name   = "rds-sg"
#   vpc_id = module.vpc.vpc_id

#   ingress {
#     description     = "Allow Postgres from SSM EC2"
#     from_port       = 5432
#     to_port         = 5432
#     protocol        = "tcp"
#     security_groups = [aws_security_group.ssm_instance.id]
#   }

#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }

#   tags = merge(local.common_tags, {
#     Name = "rds-sg"
#   })

# }

# Security group for EC2 instance
resource "aws_security_group" "ssm_instance" {
  name   = "ssm-instance-sg"
  vpc_id = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, {
    Name = "ssm-instance-sg"
  })
}
resource "aws_security_group" "ssm_endpoints" {
  name   = "ssm-endpoints-sg"
  vpc_id = module.vpc.vpc_id

  # Allow inbound 443 from EC2 SG
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }


  # Egress (not strictly needed, but keep open for responses)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "ssm-endpoints-sg"
  })
}


# IAM Role for SSM Managed Instance - make aws resource can use role to do action
resource "aws_iam_role" "ssm_role" {
  name = "ssm-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance Profile for EC2
resource "aws_iam_instance_profile" "ssm_instance_profile" {
  name = "ssm-instance-profile"
  role = aws_iam_role.ssm_role.name
  tags = local.common_tags
}

data "aws_key_pair" "ssm_key_pair" {
  key_name = "ssm-keypair"
}
# EC2 instance with SSM Agent (Amazon Linux 2 AMI includes SSM agent by default)
resource "aws_instance" "ssm_bastion" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = module.vpc.public_subnets[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.ssm_instance.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm_instance_profile.name
  key_name                    = data.aws_key_pair.ssm_key_pair.key_name

  tags      = local.common_tags
  user_data = <<-EOF
              #!/bin/bash
              set -x
              exec > /var/log/user-data.log 2>&1

              apt-get update -y
              apt-get install -y curl wget chrony

              # Ensure SSM Agent is installed via snap
              snap install amazon-ssm-agent --classic
              systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
              systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service

              systemctl enable chrony
              systemctl start chrony
              EOF
}

# Get latest Amazon Linux 2 AMI
# Get latest Ubuntu 22.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.ap-southeast-1.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.public_subnets
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled = true
  tags                = local.common_tags
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.ap-southeast-1.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.public_subnets
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled = true
  tags                = local.common_tags
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.ap-southeast-1.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.public_subnets
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled = true
  tags                = local.common_tags
}

# 4) RDS subnet group (private)
resource "aws_db_subnet_group" "db" {
  name       = "rds-db-subnets"
  subnet_ids = module.vpc.private_subnets
  tags = merge(local.common_tags, {
    Name = "rds-db-subnets"
  })
}

# 5) SG for RDS: allow only from VPN ENIs SG on port 5432
module "sg_rds" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.1"

  name        = "rds-postgres"
  description = "Allow Postgres only from SSM EC2"
  vpc_id      = module.vpc.vpc_id

  ingress_with_source_security_group_id = [
    {
      from_port                = var.db_port
      to_port                  = var.db_port
      protocol                 = "tcp"
      source_security_group_id = aws_security_group.ssm_instance.id
      description              = "psql from SSM EC2"
    }
  ]

  egress_with_cidr_blocks = [
    { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = "0.0.0.0/0" }
  ]
  tags = merge(local.common_tags, {
    Name = "rds-postgres"
  })
}

# 6) RDS PostgreSQL (single-AZ for demo, private)
module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.6"

  identifier           = "lms-postgres"
  engine               = "postgres"
  engine_version       = "17.6"       # pick a supported version for your region
  family               = "postgres17" # for parameter group
  major_engine_version = "17"


  instance_class = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 30

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
  port     = var.db_port

  multi_az               = false
  publicly_accessible    = false
  create_db_subnet_group = false
  db_subnet_group_name   = aws_db_subnet_group.db.name

  vpc_security_group_ids = [module.sg_rds.security_group_id]

  # OPTIONAL: enable IAM DB auth — then create DB users with rds_iam
  iam_database_authentication_enabled = false

  backup_retention_period = 1
  skip_final_snapshot     = true

  tags = merge(local.common_tags, {
    Name = "lms-postgres"
  })
}
