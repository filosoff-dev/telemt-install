#!/bin/bash

WORKDIR="/opt/telemt"

install_docker() {
  echo "== Проверка Docker =="

  if ! command -v docker &> /dev/null; then
    echo "Docker не найден → установка..."
    apt-get update
    apt-get install -y docker.io curl
    systemctl enable docker
    systemctl start docker
  else
    echo "✔ Docker установлен"
  fi

  echo "== Проверка Docker Compose =="

  if docker compose version &> /dev/null; then
    echo "✔ docker compose (v2) уже есть"
  else
    echo "Удаляем старый docker-compose..."
    apt-get remove -y docker-compose

    echo "Устанавливаем docker compose plugin..."
    apt-get install -y docker-compose-plugin
  fi
}

install_telemt() {
  echo "== Установка / Обновление TELEMT =="

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
    echo "Определяем IP..."
    DOMAIN=$(curl -s https://api.ipify.org)
    echo "✔ $DOMAIN"
  fi

  read -p "Порт: " PORT

  if ss -tulpn | grep -q ":$PORT "; then
    echo "❌ Порт занят"
    return
  fi

  install_docker

  mkdir -p $WORKDIR
  cd $WORKDIR

  SECRET=$(openssl rand -hex 16)

  echo "Создаём конфиг..."

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

  echo "== Перезапуск TELEMT =="

  docker rm -f telemt 2>/dev/null
  docker compose pull
  docker compose up -d

  echo "Ждём запуск..."
  sleep 5

  if ! docker ps | grep -q telemt; then
    echo "❌ TELEMT не запустился"
    docker logs telemt
    return
  fi

  if ! ss -tulpn | grep -q ":$PORT "; then
    echo "❌ Порт не слушается"
    docker logs telemt
    return
  fi

  echo ""
  echo "===== ГОТОВО ====="
  echo "✔ TELEMT работает"

  echo ""
  echo "Ссылка:"
  echo "tg://proxy?server=$DOMAIN&port=$PORT&secret=ee${SECRET}636c6f7564666c6172652e636f6d"
}

remove_telemt() {
  echo "== Удаление TELEMT =="

  docker rm -f telemt 2>/dev/null
  rm -rf $WORKDIR

  echo "✔ Удалено полностью"
}

show_link() {
  if [ ! -f "$WORKDIR/config.toml" ]; then
    echo "❌ TELEMT не установлен"
    return
  fi

  DOMAIN=$(grep public_host $WORKDIR/config.toml | cut -d '"' -f2)
  SECRET=$(grep main $WORKDIR/config.toml | cut -d '"' -f2)
  PORT=$(grep -oP '[0-9]+:443' $WORKDIR/docker-compose.yml | cut -d ':' -f1)

  echo ""
  echo "Ссылка:"
  echo "tg://proxy?server=$DOMAIN&port=$PORT&secret=ee${SECRET}636c6f7564666c6172652e636f6d"
}

show_status() {
  docker ps | grep telemt || echo "❌ TELEMT не запущен"
}

while true; do
  echo ""
  echo "===== TELEMT MANAGER ====="
  echo "1) Установить / Обновить"
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
