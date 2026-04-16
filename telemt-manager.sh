#!/bin/bash

WORKDIR="/opt/telemt"

install_telemt() {
  echo "== Установка TELEMT =="

  echo ""
  echo "Рекомендуемые порты:"
  echo "2053 2083 2087 2096 8443"
  echo ""

  echo "1) Использовать домен"
  echo "2) Использовать IP"
  read -p "Выбор (1/2): " MODE

  if [ "$MODE" = "1" ]; then
    read -p "Введите домен: " DOMAIN
  else
    echo "Определяем внешний IP..."
    DOMAIN=$(curl -s https://api.ipify.org)
    echo "✔ IP: $DOMAIN"
  fi

  read -p "Порт: " PORT

  if ss -tulpn | grep -q ":$PORT "; then
    echo "❌ Порт занят"
    return
  fi

  echo ""
  echo "== Проверка системы =="

  apt-get update

  UPDATES=$(apt-get -s upgrade | grep "^Inst" | wc -l)

  if [ "$UPDATES" -gt 0 ]; then
    echo "Найдено обновлений: $UPDATES"
    read -p "Обновить систему? (y/n): " DO_UPDATE
    if [ "$DO_UPDATE" = "y" ]; then
      apt-get upgrade -y
    fi
  else
    echo "✔ Система актуальна"
  fi

  echo ""
  echo "== Проверка Docker =="

  if ! command -v docker &> /dev/null; then
    echo "Устанавливаем Docker..."
    apt-get install -y docker.io docker-compose curl openssl
    systemctl enable docker
    systemctl start docker
  else
    echo "✔ Docker уже установлен"
    systemctl start docker
  fi

  mkdir -p $WORKDIR
  cd $WORKDIR

  SECRET=$(openssl rand -hex 16)

  cat > config.toml <<EOF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "$DOMAIN"

[server]
port = 443

[server.api]
enabled = true
listen = "0.0.0.0:9091"
whitelist = ["127.0.0.0/8", "172.16.0.0/12"]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "cloudflare.com"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
main = "$SECRET"
EOF

  cat > docker-compose.yml <<EOF
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt
    restart: unless-stopped
    ports:
      - "$PORT:443"
      - "127.0.0.1:9091:9091"
    working_dir: /run/telemt
    volumes:
      - ./config.toml:/run/telemt/config.toml:ro
    tmpfs:
      - /run/telemt:rw,mode=1777,size=1m
    environment:
      - RUST_LOG=info
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    security_opt:
      - no-new-privileges:true
EOF

  echo "Запуск контейнера..."
  docker-compose up -d

  echo ""
  echo "===== ГОТОВО ====="
  echo "Ссылка:"
  echo "tg://proxy?server=$DOMAIN&port=$PORT&secret=ee${SECRET}636c6f7564666c6172652e636f6d"
}

remove_telemt() {
  echo "Удаление TELEMT..."
  docker-compose -f $WORKDIR/docker-compose.yml down
  rm -rf $WORKDIR
  echo "✔ Удалено"
}

show_link() {
  DOMAIN=$(grep public_host $WORKDIR/config.toml | cut -d '"' -f2)
  SECRET=$(grep main $WORKDIR/config.toml | cut -d '"' -f2)
  PORT=$(grep -oP '[0-9]+:443' $WORKDIR/docker-compose.yml | cut -d ':' -f1)

  echo ""
  echo "Ссылка:"
  echo "tg://proxy?server=$DOMAIN&port=$PORT&secret=ee${SECRET}636c6f7564666c6172652e636f6d"
}

show_status() {
  docker ps | grep telemt || echo "TELEMT не запущен"
}

while true; do
  echo ""
  echo "===== TELEMT MANAGER ====="
  echo "1) Установить"
  echo "2) Удалить"
  echo "3) Показать ссылку"
  echo "4) Статус"
  echo "0) Выход"
  echo ""

  read -p "Выбор: " CHOICE

  case $CHOICE in
    1) install_telemt ;;
    2) remove_telemt ;;
    3) show_link ;;
    4) show_status ;;
    0) exit ;;
  esac
done
