#!/bin/bash

# Включение перенаправления IP
echo 1 > /proc/sys/net/ipv4/ip_forward

# Настройка iptables для NAT
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o eth1 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
