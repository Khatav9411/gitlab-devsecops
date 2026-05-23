variable "resource_group_name" {
  type        = string
  default     = "rg-aks-poc"
  description = "Resource group for AKS POC"
}

variable "location" {
  type        = string
  default     = "centralindia"
  description = "Azure region"
}

variable "cluster_name" {
  type        = string
  default     = "aks-poc"
  description = "AKS cluster name"
}

variable "kubernetes_version" {
  type        = string
  default     = null
  description = "Optional pinned Kubernetes version. Null = latest stable."
}

variable "node_count" {
  type        = number
  default     = 1
  description = "Number of nodes in the default node pool"
}

variable "node_vm_size" {
  type        = string
  default     = "Standard_B2s"
  description = "VM size for the default node pool (POC: burstable + cheap)"
}

variable "tags" {
  type = map(string)
  default = {
    environment = "poc"
    managed_by  = "terraform"
    project     = "gitlab-devsecops-poc"
  }
}
