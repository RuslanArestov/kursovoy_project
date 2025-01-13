#Выводим несколько адресов для Instance Group
/*output "web_server_ip" {
  value = yandex_compute_instance_group.web_server.instances[*].network_interface[0].ip_address
}

output "prometheus_ip" {
  value = yandex_compute_instance.prometheus.network_interface[0].ip_address
}

output "grafana_ip" {
  value = yandex_compute_instance.grafana.network_interface[0].ip_address
}

output "elasticsearch_ip" {
  value = yandex_compute_instance.elasticsearch.network_interface[0].ip_address
}

output "kibana_ip" {
  value = yandex_compute_instance.kibana.network_interface[0].ip_address
}

output "bastion_ip" {
  value = yandex_compute_instance.bastion_host.network_interface[0].nat.ip_address
}*/