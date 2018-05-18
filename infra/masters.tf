variable "master0_ami" {}
variable "master_ami" {}
variable "master_type" {}

resource "aws_security_group" "master_sg" {
  name   = "master_sg"
  vpc_id = "${var.vpc_id}"

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 10250
    to_port     = 10255
    protocol    = "TCP"
    cidr_blocks = ["10.0.0.0/16"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # calico typha
  ingress {
    from_port   = 5473
    to_port     = 5473
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  tags {
    Name = "heptio-master"
    vendor = "heptio"
  }
}

resource "aws_security_group" "master_lb_sg" {
  name   = "master_lb_sg"
  vpc_id = "${var.vpc_id}"

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  tags {
    Name = "heptio-k8s-api-lb"
    vendor = "heptio"
  }
}

resource "aws_instance" "master0_node" {
  count                       = 1
  ami                         = "${var.master0_ami}"
  instance_type               = "${var.master_type}"
  subnet_id                   = "${var.primary_subnet}"
  vpc_security_group_ids      = ["${aws_security_group.master_sg.id}"]
  key_name                    = "${var.key_name}"
  associate_public_ip_address = "true"
  tags {
    Name = "heptio-master0"
    vendor = "heptio"
  }
}

resource "aws_instance" "master_node" {
  count                       = 2
  ami                         = "${var.master_ami}"
  instance_type               = "${var.master_type}"
  subnet_id                   = "${var.primary_subnet}"
  vpc_security_group_ids      = ["${aws_security_group.master_sg.id}"]
  key_name                    = "${var.key_name}"
  associate_public_ip_address = "true"
  tags {
    Name = "heptio-master"
    vendor = "heptio"
  }
}

resource "aws_elb" "api_elb_external" {
  subnets                   = ["${var.primary_subnet}"]
  internal                  = "false"
  instances                 = ["${aws_instance.master0_node.id}", "${aws_instance.master_node.*.id}"]
  security_groups           = ["${aws_security_group.master_lb_sg.id}"]
  cross_zone_load_balancing = "true"

  listener {
    instance_port     = 6443
    instance_protocol = "TCP"
    lb_port           = 6443
    lb_protocol       = "TCP"
  }

  tags {
    Name = "heptio-k8s-api-lb"
    vendor = "heptio"
  }
}

output "master0_ep" {
  value = "${aws_instance.master0_node.public_dns}"
}

output "master0_ip" {
  value = "${aws_instance.master0_node.private_ip}"
}

output "master_ep" {
  value = "${aws_instance.master_node.*.public_dns}"
}

output "api_lb_ep" {
  value = "${aws_elb.api_elb_external.dns_name}"
}

