//  Setup the core provider information.
provider "aws" {
  access_key  = "${var.access_key}"
  secret_key  = "${var.secret_key}"
  region      = "${var.region}"
}

data "aws_ami" "amazonlinux" {
  most_recent = true

  owners = ["137112412989"]

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "name"
    values = ["amzn-ami-hvm-*"]
  }
}

//  Create a role which consul instances will assume.
//  This role has a policy saying it can be assumed by ec2
//  instances.
resource "aws_iam_role" "consul-instance-role" {
  name = "consul-instance-role"
  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "sts:AssumeRole",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Effect": "Allow",
            "Sid": ""
        }
    ]
}
EOF
}

//  The policy allows an instance to forward logs to CloudWatch, and
//  create the Log Stream or Log Group if it doesn't exist.
resource "aws_iam_policy" "forward-logs" {
  name        = "consul-node-forward-logs"
  path        = "/"
  description = "Allows an instance to forward logs to CloudWatch"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
    ],
      "Resource": [
        "arn:aws:logs:*:*:*"
    ]
  }
 ]
}
    EOF
}

//  This policy allows an instance to discover a consul cluster leader.
resource "aws_iam_policy" "leader-discovery" {
    name = "consul-node-leader-discovery"
    path = "/"
    policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Stmt1468377974000",
            "Effect": "Allow",
            "Action": [
                "autoscaling:DescribeAutoScalingInstances",
                "autoscaling:DescribeAutoScalingGroups",
                "ec2:DescribeInstances"
            ],
            "Resource": [
                "*"
            ]
        }
    ]
}
    EOF
}

//  Attach the policies to the role.
resource "aws_iam_policy_attachment" "consul-instance-forward-logs" {
  name       = "consul-instance-forward-logs"
  roles      = ["${aws_iam_role.consul-instance-role.name}"]
  policy_arn = "${aws_iam_policy.forward-logs.arn}"
}

//  Attach the policy to the role.
resource "aws_iam_policy_attachment" "consul-instance-leader-discovery" {
    name = "consul-instance-leader-discovery"
    roles = ["${aws_iam_role.consul-instance-role.name}"]
    policy_arn = "${aws_iam_policy.leader-discovery.arn}"
}

//  Create a instance profile for the role.
resource "aws_iam_instance_profile" "consul-instance-profile" {
    name = "consul-instance-profile"
    role = "${aws_iam_role.consul-instance-role.name}"
}

//  Define the VPC.
resource "aws_vpc" "consul-cluster" {
  cidr_block = "10.0.0.0/16" // i.e. 10.0.0.0 to 10.0.255.255
  enable_dns_hostnames = true
  tags = {
    Name = "Consul Cluster VPC"
    Project = "consul-cluster"
  }
}

//  Create an Internet Gateway for the VPC.
resource "aws_internet_gateway" "consul-cluster" {
  vpc_id = "${aws_vpc.consul-cluster.id}"

  tags = {
    Name    = "Consul Cluster IGW"
    Project = "consul-cluster"
  }
}

//  Create a public subnet for each AZ.
resource "aws_subnet" "public-a" {
  vpc_id                  = "${aws_vpc.consul-cluster.id}"
  cidr_block              = "10.0.1.0/24" // i.e. 10.0.1.0 to 10.0.1.255
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  depends_on              = ["aws_internet_gateway.consul-cluster"]
  tags = {
    Name = "Subnet 1"
    Project = "consul-cluster"
  }
}
resource "aws_subnet" "public-b" {
  vpc_id                  = "${aws_vpc.consul-cluster.id}"
  cidr_block              = "10.0.2.0/24" // i.e. 10.0.2.0 to 10.0.1.255
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  depends_on              = ["aws_internet_gateway.consul-cluster"]
  tags = {
    Name = "Subnet 2"
    Project = "consul-cluster"
  }
}

//  Create a route table allowing all addresses access to the IGW.
resource "aws_route_table" "public" {
  vpc_id = "${aws_vpc.consul-cluster.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.consul-cluster.id}"
  }

  tags = {
    Name    = "Consul Cluster Public Route Table"
    Project = "consul-cluster"
  }
}

//  Now associate the route table with the public subnet - giving
//  all public subnet instances access to the internet.
resource "aws_route_table_association" "public-a" {
  subnet_id      = "${aws_subnet.public-a.id}"
  route_table_id = "${aws_route_table.public.id}"
}

resource "aws_route_table_association" "public-b" {
  subnet_id      = "${aws_subnet.public-b.id}"
  route_table_id = "${aws_route_table.public.id}"
}

//  Create an internal security group for the VPC, which allows everything in the VPC
//  to talk to everything else.
resource "aws_security_group" "consul-cluster-vpc" {
  name        = "consul-cluster-vpc"
  description = "Default security group that allows inbound and outbound traffic from all instances in the VPC"
  vpc_id      = "${aws_vpc.consul-cluster.id}"

  ingress {
    from_port = "0"
    to_port   = "0"
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port = "0"
    to_port   = "0"
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port   = "80"
    to_port     = "80"
    protocol    = "6"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = "443"
    to_port     = "443"
    protocol    = "6"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "Consul Cluster Internal VPC"
    Project = "consul-cluster"
  }
}

//  Create a security group allowing web access to the public subnet.
resource "aws_security_group" "consul-cluster-public-web" {
  name        = "consul-cluster-public-web"
  description = "Security group that allows web traffic from internet"
  vpc_id      = "${aws_vpc.consul-cluster.id}"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  //  The Consul admin UI is exposed over 8500...
  ingress {
    from_port   = 8500
    to_port     = 8500
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "Consul Cluster Public Web"
    Project = "consul-cluster"
  }
}

//  Create a security group which allows ssh access from the web.
//  Remember: This is *not* secure for production! In production, use a Bastion.
resource "aws_security_group" "consul-cluster-public-ssh" {
  name        = "consul-cluster-public-ssh"
  description = "Security group that allows SSH traffic from internet"
  vpc_id      = "${aws_vpc.consul-cluster.id}"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "Consul Cluster Public SSH"
    Project = "consul-cluster"
  }
}

//  Launch configuration for the consul cluster auto-scaling group.
resource "aws_launch_configuration" "consul-cluster-lc" {
    name_prefix = "consul-node-"
    image_id = "${data.aws_ami.amazonlinux.image_id}"
    instance_type = "t2.micro"
    iam_instance_profile = "${aws_iam_instance_profile.consul-instance-profile.id}"
    user_data = "${file("files/consul-node.sh")}"
     security_groups = [
      "${aws_security_group.consul-cluster-vpc.id}",
      "${aws_security_group.consul-cluster-public-web.id}",
      "${aws_security_group.consul-cluster-public-ssh.id}",
    ]
    lifecycle {
        create_before_destroy = true
    }
}

//  Auto-scaling group for our cluster.
resource "aws_autoscaling_group" "consul-cluster-asg" {
    depends_on           = ["aws_launch_configuration.consul-cluster-lc"]
    name = "consul-asg"
    launch_configuration = "${aws_launch_configuration.consul-cluster-lc.name}"
    min_size = 5
    max_size = 7
    vpc_zone_identifier = [
        "${aws_subnet.public-a.id}",
        "${aws_subnet.public-b.id}"
    ]
    load_balancers       = ["${aws_elb.consul-lb.name}"]
    lifecycle {
        create_before_destroy = true
    }
    tag {
      key                 = "Name"
      value               = "consulnode"
      propagate_at_launch = true
    }
    tag {
      key                 = "Project"
      value               = "consul-cluster"
      propagate_at_launch = true
    }
}

resource "aws_elb" "consul-lb" {
    name = "consul-lb-a"
    security_groups = [
        "${aws_security_group.consul-cluster-vpc.id}",
        "${aws_security_group.consul-cluster-public-web.id}"
    ]
    subnets = [
        "${aws_subnet.public-a.id}",
        "${aws_subnet.public-b.id}"
    ]
    listener {
        instance_port = 8500
        instance_protocol = "http"
        lb_port = 8500
        lb_protocol = "http"
    }
    health_check {
        healthy_threshold = 2
        unhealthy_threshold = 2
        timeout = 3
        target = "HTTP:8500/ui/"
        interval = 30
    }
}

output "consul-dns" {
    value = "${aws_elb.consul-lb.dns_name}"
}