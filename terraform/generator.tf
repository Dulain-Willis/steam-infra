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

  # user_data only ever runs at first boot, so without this an injection-rate
  # override lands in state and changes nothing about the running generator:
  # the container keeps the environment it booted with. That silently defeats
  # the whole point of #130's knobs -- the spec wants a fault "forced to appear
  # in minutes during verification", and a knob you can only set by tearing the
  # stack down and bringing it back up is not that. Replacing the instance is
  # cheap here (the generator is stateless; it rebuilds its image on boot) and
  # it makes `tofu apply -var <rate>=...` mean what it looks like it means.
  user_data_replace_on_change = true

  # ponytail: builds the image on-box from source inlined into user_data
  # (no registry, no image versioning, full docker build on every boot).
  # Revisit with an ECR image + pull-on-boot if generator code outgrows
  # the reboot-to-deploy cycle. See #19. gzip'd because plaintext source
  # blew past EC2's 16KB user_data cap once dirty.py was added; cloud-init
  # auto-decompresses gzip user_data, so this buys headroom without
  # restructuring the inline-source mechanism itself.
  user_data_base64 = base64gzip(templatefile("${path.module}/generator_user_data.sh.tpl", {
    dockerfile   = file("${path.module}/../generator/Dockerfile")
    requirements = file("${path.module}/../generator/requirements.txt")
    generator_py = file("${path.module}/../generator/generator.py")
    dirty_py     = file("${path.module}/../generator/dirty.py")
    db_host      = aws_db_instance.main.address
    db_port      = "5432"
    db_name      = aws_db_instance.main.db_name
    db_user      = aws_db_instance.main.username
    db_password  = random_password.db.result
    # Calibrated (#16) to land combined event-table throughput at ~1-3
    # events/sec against the seeded 50k-user/3k-game catalog. See
    # docs/generator-runbook.md for the measured run.
    tick_min_seconds = "1"
    tick_max_seconds = "2"

    # Dirty-data injection overrides (#130) -- one tf variable per env var
    # generator/dirty.py reads, see variables.tf for the convention.
    refund_reason_null_rate                 = var.refund_reason_null_rate
    duplicate_rate_wishlist_items           = var.duplicate_rate_wishlist_items
    duplicate_rate_playtime_sessions        = var.duplicate_rate_playtime_sessions
    duplicate_rate_purchases                = var.duplicate_rate_purchases
    purchase_recorded_at_jitter_max_seconds = var.purchase_recorded_at_jitter_max_seconds
    review_recorded_at_jitter_max_seconds   = var.review_recorded_at_jitter_max_seconds
    snapshot_recorded_at_jitter_max_seconds = var.snapshot_recorded_at_jitter_max_seconds
    orphan_never_arrives_rate               = var.orphan_never_arrives_rate
    orphan_late_arrival_rate                = var.orphan_late_arrival_rate
    orphan_late_arrival_delay_seconds       = var.orphan_late_arrival_delay_seconds
    late_arrival_rate                       = var.late_arrival_rate
    late_arrival_max_days                   = var.late_arrival_max_days
    payment_method_new_onset_date           = var.payment_method_new_onset_date
    restatement_weight                      = var.restatement_weight
  }))

  tags = {
    Name = "steam-infra-generator"
  }
}
