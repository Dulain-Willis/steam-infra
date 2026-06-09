variable "region" {                                                                                                                                    
  description = "AWS region"                                                                                                                           
  type        = string                                                                                                                                 
  default     = "us-east-1"                                                                                                                            
}                                                                                                                                                      
                
variable "control_plane_instance_type" {
  description = "EC2 instance type for Kubernetes control plane"
  type        = string 
  default     = "t2.medium"
}

variable "worker_instance_type" {                                                                                                                           
  description = "EC2 instance type for Kubernetes worker node"
  type        = string                      
  default     = "t3.2xlarge"            
}
                                                                                                                                                         
variable "control_plane_volume_gb" {                                                                                                                   
  description = "Root EBS volume size in GB for control plane"
  type        = number                                                                                                                                 
  default     = 20                                                                                                                                   
}                                                                                                                                                      
   
variable "worker_volume_gb" {                                                                                                                          
  description = "Root EBS volume size in GB for worker"                                                                                              
  type        = number
  default     = 30
}

variable "cluster_name" {                                                                                                                              
  description = "Name of the Kubernetes cluster"
  type        = string                                                                                                                                 
  default     = "steam-cluster"                                                                                                                      
}
