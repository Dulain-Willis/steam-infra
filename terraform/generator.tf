resource "aws_security_group" "generator" {
  name        = "steam-infra-generator"
  description = "SSM-managed generator host, no inbound ports"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "steam-infra-generator"
  }
}

resource "aws_iam_role" "generator" {
  name               = "steam-infra-generator"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume.json
}

resource "aws_iam_role_policy_attachment" "generator_ssm" {
  role       = aws_iam_role.generator.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "generator" {
  name = "steam-infra-generator"
  role = aws_iam_role.generator.name
}

resource "aws_instance" "generator" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t4g.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.generator.id]
  iam_instance_profile        = aws_iam_instance_profile.generator.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/generator_user_data.sh.tpl", {
    dockerfile       = file("${path.module}/../generator/Dockerfile")
    requirements     = file("${path.module}/../generator/requirements.txt")
    heartbeat_py     = file("${path.module}/../generator/heartbeat.py")
    db_host          = aws_db_instance.main.address
    db_port          = "5432"
    db_name          = aws_db_instance.main.db_name
    db_user          = aws_db_instance.main.username
    db_password      = random_password.db.result
    tick_min_seconds = "5"
    tick_max_seconds = "15"
  })

  tags = {
    Name = "steam-infra-generator"
  }
}
