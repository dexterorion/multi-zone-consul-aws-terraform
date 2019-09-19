variable "access_key" {
	default = "your-access-key"	
}

variable "secret_key" {
	default = "your-secret-key"
}

variable "public_key_path" {
	default = "~/.ssh/id_rsa.pub"
}

variable "region" {
	default = "ap-southeast-1"
}

variable "amisize" {
  description = "The size of the cluster nodes, e.g: t2.micro"
  default = "t2.micro"
}

variable "asgname" {
  description = "The auto-scaling group name, e.g: consul-asg"
  default = "consul-asg"
}