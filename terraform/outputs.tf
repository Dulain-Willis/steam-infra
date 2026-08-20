output "bastion_instance_id" {
  value = aws_instance.bastion.id
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}
