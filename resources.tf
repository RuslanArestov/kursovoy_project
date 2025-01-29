##############Создание VPC и подсетей, и таблицы маршрутизации###############

resource "yandex_vpc_network" "network" {
  name = "network"
}

resource "yandex_vpc_subnet" "private-subnet-1" {
  name           = "private-subnet-1"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["192.168.10.0/24"]
  route_table_id = yandex_vpc_route_table.private_route_table.id
}

resource "yandex_vpc_subnet" "private-subnet-2" {
  name           = "private-subnet-2"
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["192.168.20.0/24"]
  route_table_id = yandex_vpc_route_table.private_route_table.id
}

resource "yandex_vpc_subnet" "public-subnet" {
  name           = "public-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["192.168.30.0/24"]
  route_table_id = yandex_vpc_route_table.public_route_table.id
}

# Интернет-Шлюз
resource "yandex_vpc_gateway" "internet_gateway" {
  name = "internet-gateway"
}

# Таблица маршрутизации для bastion
resource "yandex_vpc_route_table" "public_route_table" {
  name       = "public-route-table"
  network_id = yandex_vpc_network.network.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.internet_gateway.id
  }
}

# Таблица маршрутизации для приватных сетей без NAT
resource "yandex_vpc_route_table" "private_route_table" {
  name       = "private-route-table"
  network_id = yandex_vpc_network.network.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    next_hop_address   = yandex_compute_instance.bastion_host.network_interface[0].ip_address
  }
}


##############Создание VPC и подсетей, и таблицы маршрутизации###############

##########################Создание Security Groups###########################

resource "yandex_vpc_security_group" "web-sg" {
  name       = "web-sg"
  network_id = yandex_vpc_network.network.id

  ingress {
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

   ingress {
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

   ingress {
    description    = "Allow health checks"
    protocol       = "TCP"
    port           = 30080
    v4_cidr_blocks = ["198.18.235.0/24", "198.18.248.0/24"]
  }

  ingress {
    protocol = "TCP"
    port     = 22
    security_group_id = yandex_vpc_security_group.bastion-sg.id
  }

  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_vpc_security_group" "bastion-sg" {
  name       = "bastion-sg"
  network_id = yandex_vpc_network.network.id

  ingress {
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

##########################Создание Security Groups###########################

###############Создание сервисного аккаунта и назначение ролей###############

resource "yandex_iam_service_account" "ig-sa" {
  name        = "ig-sa"
  description = "Сервисный аккаунт для Instance Group"
}

resource "yandex_resourcemanager_folder_iam_member" "editor" {
  folder_id = var.folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.ig-sa.id}"
}

# Если уже есть сервисный аккаунт, то используем его, а не создаем новый
#data "yandex_iam_service_account" "terraform" {
#  name = "terraform"
#}

###############Создание сервисного аккаунта и назначение ролей###############

###########################Создание Instance Group###########################
#В Instance Group создается шаблон ВМ, которые можно автоматически масштабировать.
#В данном случае создам шаблон для ВМ с Nginx, между которыми будет балансировать http-трафик,
#поступающий от Application load balancer

resource "yandex_compute_instance_group" "web_server" {
  name                = "fixed-ig-with-balancer"
  folder_id           = var.folder_id
  #Использование существующего id серввисного аккаунта
  #service_account_id  = data.yandex_iam_service_account.terraform.id
  service_account_id  = yandex_iam_service_account.ig-sa.id
  deletion_protection = false

  instance_template {
    platform_id = "standard-v1"
    name        = "web-server-{instance.index}"
    resources {
      core_fraction = 100
      memory        = 2
      cores         = 2
    }

    boot_disk {
      mode = "READ_WRITE"
      initialize_params {
        image_id = data.yandex_compute_image.ubuntu.image_id 
        type     = "network-hdd"
        size     = 10
      }
    }

     scheduling_policy {
     preemptible = true  # Прерываемая ВМ
    }

    network_interface {
      subnet_ids         = [yandex_vpc_subnet.private-subnet-1.id, yandex_vpc_subnet.private-subnet-2.id]
      security_group_ids = [yandex_vpc_security_group.web-sg.id]
      nat                = false # Устанавливаем только приватный адрес
    }

    metadata = {
    user-data = data.template_file.cloudinit_web.rendered
    }
  }

  labels = {
      ansible_group = "web_servers" # Хосты в динамический inventory группируются на основе метки ansible_group
  }

  scale_policy {
    auto_scale {
      cpu_utilization_target = 75
      min_zone_size        = 1  # Минимальное количество ВМ в одной зоне доступности
      max_size             = 3  # Максимальное количество ВМ в группе
      initial_size         = 2  # Начальное количество ВМ в группе
      measurement_duration = "60"  # Продолжительность измерения нагрузки. Если это значение превысит целевое значение метрики для масштабирования, то Instance Groups увеличит количество ВМ в группе
    }
  }

  allocation_policy {
    zones = ["ru-central1-a", "ru-central1-b"]
  }

  deploy_policy {
    max_unavailable = 1
    max_expansion   = 0
  }

  application_load_balancer {
    target_group_name        = "target-group"
    target_group_description = "Целевая группа Network Load Balancer"
    target_group_labels      = {
      env = "production"
    }
  }
}

###########################Создание Instance Group###########################

###########################Создание Backend Group############################

resource "yandex_alb_backend_group" "backend-group" {
  name = "backend-group"

  session_affinity {
    cookie {
      name = "session_cookie"
      ttl  = "30m"
    }
  }

  http_backend {
    name             = "test-backend"
    weight           = 1
    port             = 80
    target_group_ids = [yandex_compute_instance_group.web_server.application_load_balancer[0].target_group_id] # Привязка Instance Group
    load_balancing_config {
      panic_threshold = 90
      mode = "MAGLEV_HASH"
    }
    healthcheck {
      timeout             = "10s"
      interval            = "2s"
      healthy_threshold   = 10
      unhealthy_threshold = 15
      http_healthcheck {
        path = "/"
        host = "localhost"
      }
    }
  }
}

###########################Создание Backend Group############################

############################Создание HTTP Router#############################

resource "yandex_alb_http_router" "tf-router" {
  name   = "tf-router"
  labels = {
    tf-label    = "tf-label-value"
    empty-label = ""
  }
}

resource "yandex_alb_virtual_host" "my-virtual-host" {
  name           = "my-virtual-host"
  http_router_id = yandex_alb_http_router.tf-router.id

  route {
    name = "my-route"
    http_route {
      http_route_action {
        backend_group_id = yandex_alb_backend_group.backend-group.id # Привязка Backend Group
        timeout          = "60s"
      }
    }
  }
}

############################Создание HTTP Router#############################

#####################Создание Application Load Balancer######################

resource "yandex_logging_group" "log-group" {
  name             = "alb-log-group"
  folder_id        = var.folder_id
  retention_period = "24h"
}

resource "yandex_alb_load_balancer" "balancer" {
  name               = "balancer"
  network_id         = yandex_vpc_network.network.id
  security_group_ids = [yandex_vpc_security_group.web-sg.id]

  allocation_policy {
    location {
      zone_id   = "ru-central1-a"
      subnet_id = yandex_vpc_subnet.public-subnet.id
    }
  }

  listener {
    name = "http-listener"
    endpoint {
      address {
        external_ipv4_address {
        }
      }
      ports = [80]
    }
    http {
      handler {
        http_router_id = yandex_alb_http_router.tf-router.id # Привязка Http-router
      }
    }
  }

  log_options {
    log_group_id = yandex_logging_group.log-group.id
    discard_rule {
      http_codes          = ["404"]
      http_code_intervals = ["HTTP_5XX"]
      grpc_codes          = ["NOT_FOUND"]
      discard_percent     = 50
    }
  }
}

#####################Создание Application Load Balancer######################

############################Создание Bastion Host############################

resource "yandex_compute_instance" "bastion_host" {
  name        = "bastion_host"
  platform_id = "standard-v1"
  zone        = "ru-central1-a"
  allow_stopping_for_update   = true

  resources {
    core_fraction = 5
    memory = 2
    cores  = 2
  }

  boot_disk {
      mode = "READ_WRITE"
      initialize_params {
        image_id = data.yandex_compute_image.nat-instance.image_id 
        type     = "network-hdd"
        size     = 10
      }
    }

  scheduling_policy {
    preemptible = true
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.public-subnet.id
    security_group_ids = [yandex_vpc_security_group.bastion-sg.id]
    nat                = true # Устанавливаем публичный адрес
  }

  # network_interface {
  #   subnet_id          = yandex_vpc_subnet.private-subnet-1
  #   security_group_ids = [yandex_vpc_security_group.web-sg]
  #   nat                = false
  # }

  # network_interface {
  #   subnet_id          = yandex_vpc_subnet.private-subnet-2
  #   security_group_ids = [yandex_vpc_security_group.web-sg]
  #   nat                = false
  # }

  metadata = {
    user-data = data.template_file.cloudinit_bastion.rendered
  }

  # provisioner "file" {
  #   source      = "nat-setup.sh"
  #   destination = "/tmp/nat-setup.sh"
  # }

  # provisioner "remote-exec" {
  #   inline = [
  #     "chmod +x /tmp/nat-setup.sh",
  #     "/tmp/nat-setup.sh"
  #   ]

  #   connection {
  #     type        = "ssh"
  #     user        = "sysadmin"
  #     private_key = file("~/.ssh/bastion")
  #     host        = yandex_compute_instance.bastion_host.network_interface[0].nat_ip_address
  #   }
  # }

  labels = {
    ansible_group = "bastion_host"
  }
}

############################Создание Bastion Host############################

#########Создание ВМ для Prometheus, Grafana, Elasticsearch и Kibana#########

resource "yandex_compute_instance" "prometheus" {
  name        = "prometheus"
  platform_id = "standard-v1"
  zone        = "ru-central1-a"
  allow_stopping_for_update   = true

  resources {
    core_fraction = 5
    memory        = 2
    cores         = 2
  }

  boot_disk {
      mode = "READ_WRITE"
      initialize_params {
        image_id = data.yandex_compute_image.ubuntu.image_id 
        type     = "network-hdd"
        size     = 10
      }
    }

  scheduling_policy {
    preemptible = true
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.private-subnet-1.id
    security_group_ids = [yandex_vpc_security_group.web-sg.id]
    nat                = false
  }

  metadata = {
    user-data = data.template_file.cloudinit_prometheus.rendered
  }

  labels = {
    ansible_group = "prometheus"
  }
}

resource "yandex_compute_instance" "grafana" {
  name        = "grafana"
  platform_id = "standard-v1"
  zone        = "ru-central1-a"
  allow_stopping_for_update   = true

  resources {
    core_fraction = 5
    memory        = 2
    cores         = 2
  }

  boot_disk {
      mode = "READ_WRITE"
      initialize_params {
        image_id = data.yandex_compute_image.ubuntu.image_id 
        type     = "network-hdd"
        size     = 10
      }
    }

  scheduling_policy {
    preemptible = true
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.public-subnet.id
    security_group_ids = [yandex_vpc_security_group.web-sg.id]
    nat                = true
  }

  metadata = {
    user-data = data.template_file.cloudinit_grafana.rendered
  }
  
  labels = {
    ansible_group = "grafana"
  }
}

resource "yandex_compute_instance" "elasticsearch" {
  name        = "elasticsearch"
  platform_id = "standard-v1"
  zone        = "ru-central1-a"
  allow_stopping_for_update   = true

  resources {
    core_fraction = 5
    memory        = 2
    cores         = 2
  }

  boot_disk {
      mode = "READ_WRITE"
      initialize_params {
        image_id = data.yandex_compute_image.ubuntu.image_id 
        type     = "network-hdd"
        size     = 10
      }
    }

  scheduling_policy {
    preemptible = true
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.private-subnet-1.id
    security_group_ids = [yandex_vpc_security_group.web-sg.id]
    nat                = false
  }

  metadata = {
    user-data = data.template_file.cloudinit_elasticsearch.rendered
  }

  labels = {
    ansible_group = "elasticsearch"
  }
}

resource "yandex_compute_instance" "kibana" {
  name        = "kibana"
  platform_id = "standard-v1"
  zone        = "ru-central1-a"
  allow_stopping_for_update   = true

  resources {
    core_fraction = 5
    memory        = 2
    cores         = 2
  }

  boot_disk {
      mode = "READ_WRITE"
      initialize_params {
        image_id = data.yandex_compute_image.ubuntu.image_id 
        type     = "network-hdd"
        size     = 10
      }
    }

  scheduling_policy {
    preemptible = true
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.public-subnet.id
    security_group_ids = [yandex_vpc_security_group.web-sg.id]
    nat                = true
  }

  metadata = {
    user-data = data.template_file.cloudinit_kibana.rendered
  }

  labels = {
    ansible_group = "kibana"
  } 
}

# Создание шаблона для файла ~/.ssh/config
resource "template_file" "ssh_config" {
  template = <<EOT
# Настройка для всех серверов в приватных подсетях
Host 192.168.10.* 192.168.20.* 192.168.30.*
  ProxyCommand ssh -W %h:%p ${yandex_compute_instance.bastion_host.network_interface[0].nat_ip_address}
  User sysadmin

# Настройка для каждого сервера
%{for instance in yandex_compute_instance_group.web_server.instances~}
Host ${instance.network_interface[0].ip_address}
  IdentityFile ~/.ssh/web_server
%{endfor~}

Host ${yandex_compute_instance.prometheus.network_interface[0].ip_address}
  IdentityFile ~/.ssh/prometheus

Host ${yandex_compute_instance.grafana.network_interface[0].ip_address}
  IdentityFile ~/.ssh/grafana

Host ${yandex_compute_instance.elasticsearch.network_interface[0].ip_address}
  IdentityFile ~/.ssh/elasticsearch

Host ${yandex_compute_instance.prometheus.network_interface[0].ip_address}
  IdentityFile ~/.ssh/prometheus

Host ${yandex_compute_instance.kibana.network_interface[0].ip_address}
  IdentityFile ~/.ssh/kibana

# Настройка для bastion-host
Host ${yandex_compute_instance.bastion_host.network_interface[0].nat_ip_address}
  Hostname ${yandex_compute_instance.bastion_host.network_interface[0].nat_ip_address}
  User sysadmin
  IdentityFile ~/.ssh/bastion
  ControlMaster auto
  ControlPath ~/.ssh/ansible-%r@%h:%p
  ControlPersist 5m
EOT
}

# Создание файла ~/.ssh/config
resource "local_file" "ssh_config" {
  content  = template_file.ssh_config.rendered
  filename = pathexpand("~/.ssh/config")
}

#########Создание ВМ для Prometheus, Grafana, Elasticsearch и Kibana#########

#####################Генерация конфигурации  cloud-init######################

data "template_file" "cloudinit_bastion" {
  template = file("./cloud-init.yml")
  vars = {
    ssh_key = local.bastion_ssh_key
  }
}

data "template_file" "cloudinit_web" {
  template = file("./cloud-init.yml")
  vars = {
    ssh_key = local.web_server_ssh_key
  }
}

data "template_file" "cloudinit_prometheus" {
  template = file("./cloud-init.yml")
  vars = {
    ssh_key = local.prometheus_ssh_key
  }
}

data "template_file" "cloudinit_grafana" {
  template = file("./cloud-init.yml")
  vars = {
    ssh_key = local.grafana_ssh_key
  }
}

data "template_file" "cloudinit_elasticsearch" {
  template = file("./cloud-init.yml")
  vars = {
    ssh_key = local.elasticsearch_ssh_key
  }
}

data "template_file" "cloudinit_kibana" {
  template = file("./cloud-init.yml")
  vars = {
    ssh_key = local.kibana_ssh_key
  }
}

#####################Генерация конфигурации  cloud-init######################

# Считываем информацию об образе Ubuntu 20.04 LTS
data "yandex_compute_image" "ubuntu" {
  family = var.vm_web_image_family 
}

data "yandex_compute_image" "nat-instance" {
  family = var.vm_nat_instance_image_family
}

# Создаем inventory
resource "local_file" "hosts_templatefile" {
  content = templatefile("${path.module}/hosts.tftpl",
    {
      webservers = yandex_compute_instance_group.web_server.instances,
      prometheus  = [yandex_compute_instance.prometheus],
      grafana    = [yandex_compute_instance.grafana],
      elasticsearch = [yandex_compute_instance.elasticsearch],
      kibana  = [yandex_compute_instance.kibana],
      bastion    = [yandex_compute_instance.bastion_host]
    }
  )

  filename = "${abspath(path.module)}/hosts.ini"

  depends_on = [
    yandex_vpc_subnet.private-subnet-1,
    yandex_vpc_subnet.private-subnet-2
     ]
}

# resource "null_resource" "web_hosts_provision" {
#   count = var.web_provision == true ? 1 : 0
  
#   depends_on = [
#     yandex_compute_instance_group.web_server,
#     yandex_compute_instance.prometheus,
#     yandex_compute_instance.grafana,
#     yandex_compute_instance.elasticsearch,
#     yandex_compute_instance.kibana,
#     yandex_compute_instance.bastion_host
#   ]

#   provisioner "local-exec" {
#     command    = "> ~/.ssh/known_hosts && eval $(ssh-agent) | ssh-add ~/.ssh/"

#   }

#   #Запуск ansible-playbook
#   provisioner "local-exec" {
   
#     command = "ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i hosts.ini test.yml > ansible.log 2>&1"

#     environment = { ANSIBLE_HOST_KEY_CHECKING = "False" }

#   }
#   triggers = {
#     always_run      = "${timestamp()}"
#     always_run_uuid = "${uuid()}"
#   }

# }