variable "cloud_id" {
  type = string
}

variable "folder_id" {
  type = string
}

variable "image-id" {
  type = string
}

#ssh-ключи
locals {
  web_server_ssh_key     = file("~/.ssh/web_server.pub")
  prometheus_ssh_key     = file("~/.ssh/prometheus.pub")
  grafana_ssh_key        = file("~/.ssh/grafana.pub")
  elasticsearch_ssh_key  = file("~/.ssh/elasticsearch.pub")
  kibana_ssh_key         = file("~/.ssh/kibana.pub")
  bastion_ssh_key        = file("~/.ssh/bastion.pub")
}