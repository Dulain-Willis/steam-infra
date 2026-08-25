output "bastion_instance_id" {
  value = aws_instance.bastion.id
}

output "generator_instance_id" {
  value = aws_instance.generator.id
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}
