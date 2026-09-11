resource "aws_security_group" "bastion" {
  name        = "steam-infra-bastion"
  description = "SSM-managed bastion, no inbound ports"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "steam-infra-bastion"
  }
}

data "aws_iam_policy_document" "bastion_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  name               = "steam-infra-bastion"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume.json
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "steam-infra-bastion"
  role = aws_iam_role.bastion.name
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  # Must stay on the *standard* AL2023 image: al2023-ami-minimal-* ships
  # without amazon-ssm-agent, so a minimal bastion never registers with SSM
  # and bootstrap.sh Stage 2 dies at "bastion SSM agent never came online".
  # "al2023-ami-2023.*" excludes both -minimal- and -ecs-hvm-; pin the kernel
  # so most_recent doesn't flip between same-date 6.1/6.12/6.18 builds.
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-arm64"]
  }
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true

  tags = {
    Name = "steam-infra-bastion"
  }
}
