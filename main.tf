provider "aws" {
  region = "eu-west-2"
}

terraform {
  backend "s3" {
    # Replace this with your bucket name!
    bucket = "electron-terraform-up-and-running-states"
    key    = "clickhouse/dev/s3/terraform.tfstate"
    region = "eu-west-2"
    # Replace this with your DynamoDB table name!
    dynamodb_table = "electron-terraform-up-and-running-locks"
    encrypt        = false
  }
}

#  IAM Role for EC2 Instances
resource "aws_iam_role" "clickhouse_zookeeper_role" {
  name = "clickhouse_zookeeper_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

#  IAM Role Policy for EC2 Instances
resource "aws_iam_role_policy" "clickhouse_zookeeper_policy" {
  name = "clickhouse_zookeeper_policy"
  role = aws_iam_role.clickhouse_zookeeper_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:DescribeInstances"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

#  IAM Instance Profile
resource "aws_iam_instance_profile" "clickhouse_zookeeper_profile" {
  name = "clickhouse_zookeeper_profile"
  role = aws_iam_role.clickhouse_zookeeper_role.name
}

#  Security Group for ClickHouse & ZooKeeper
resource "aws_security_group" "clickhouse_sg" {
  name        = "clickhouse_sg"
  description = "Allow ClickHouse and ZooKeeper traffic"
  vpc_id      = "vpc-02c4616a"  #  Your VPC

  ingress {
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Change for security
  }

  ingress {
    from_port   = 2181
    to_port     = 2181
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # SSH Access
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#  Launch Template (ZooKeeper + ClickHouse)
resource "aws_launch_template" "clickhouse_zookeeper" {
  name_prefix   = "clickhouse-zookeeper-"
  image_id      = "ami-091f18e98bc129c4e"  # Ubuntu 24.04
  instance_type = "t3.medium"
  key_name      = "debugger"  #  Your SSH Key

  iam_instance_profile {
    name = aws_iam_instance_profile.clickhouse_zookeeper_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true
    subnet_id                   = "subnet-deae57a4"  #  Your Public Subnet
    security_groups             = [aws_security_group.clickhouse_sg.id]
  }

  user_data = base64encode(file("setup.sh"))
}

#  Auto Scaling Group (Deploys in Your Subnet)
resource "aws_autoscaling_group" "clickhouse_zookeeper" {
  desired_capacity     = 3
  max_size            = 6
  min_size            = 3
  vpc_zone_identifier = ["subnet-deae57a4"]  #  Your Public Subnet

  launch_template {
    id      = aws_launch_template.clickhouse_zookeeper.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "clickhouse-zookeeper-node"
    propagate_at_launch = true
  }
}