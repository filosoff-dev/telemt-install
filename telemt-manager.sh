#!/bin/bash

WORKDIR="/opt/telemt"

function install_telemt() {
  echo "== Установка TELEMT =="

  echo ""
  echo "Рекомендуемые порты:"
  echo "2053 2083 2087 2096 8443"
  echo ""

  echo "Выбери вариант:"
  echo "1) Использовать домен"
  echo "2) Использовать IP сервера"
  read -p "Выбор (1/2): " MODE

  if [ "$MODE" = "1" ]; then
    read -p "Домен: " DOMAIN
    [ -z "$DOMAIN" ] && echo "❌ Домен пустой" && return
  elif [ "$MODE" = "2" ]; then
    echo "Определяем внешний IP..."
    DOMAIN=$(curl -s https://api.ipify.org)
    [ -z "$DOMAIN" ] && echo "❌ Не удалось определить IP" && return
    echo "✔ IP: $DOMAIN"
  else
    echo "❌ Неверный выбор"
    return
  fi

  read -p "Порт: " PORT
  [ -z "$PORT" ] && echo "❌ Порт пустой" && return

  if ss -tulpn | grep -q ":$PORT "; then
    echo "❌ Порт занят"
    return
  fi

  echo ""
  echo "✔ Сервер: $DOMAIN"
  echo "✔ Порт: $PORT"

  echo ""
  echo "== Проверка системы =="

  apt-get update -qq
  UPDATES=$(apt-get -s upgrade | grep "^Inst" | wc -l)

  if [ "$UPDATES" -gt 0 ]; then
    echo "⚠️ Доступно обновлений: $UPDATES"
    read -p "Обновить систему? (y/n): " DO_UPDATE
    [ "$DO_UPDATE" = "y" ] && apt upgrade -y
  else
    echo "✔ Система актуальна"
  fi

  echo ""
  echo "== Проверка Docker =="

  if ! command -v docker &> /dev/null; then
    echo "Устанавливаем Docker..."
    apt install -y docker.io docker-compose curl openssl
    systemctl enable docker
    systemctl start docker
    sleep 2
  else
    echo "✔ Docker уже установлен"
    systemctl is-active --quiet docker || systemctl start docker
  fi

  if ! docker info > /dev/null 2>&1; then
    echo "❌ Docker не работает"
    return
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

  docker-compose up -d
  sleep 2

  echo ""
  echo "===== ГОТОВО ====="
  echo "Ссылка:"
  echo "tg://proxy?server=$DOMAIN&port=$PORT&secret=ee${SECRET}636c6f7564666c6172652e636f6d"
}

function remove_telemt() {
  echo "== Удаление TELEMT =="

  docker-compose -f $WORKDIR/docker-compose.yml down 2>/dev/null
  docker rm -f telemt 2>/dev/null

  rm -rf $WORKDIR

  echo "✔ Удалено"
}

function show_link() {
  if [ ! -f "$WORKDIR/config.toml" ]; then
    echo "❌ config не найден"
    return
  fi

  DOMAIN=$(grep public_host $WORKDIR/config.toml | cut -d '"' -f2)
  SECRET=$(grep main $WORKDIR/config.toml | cut -d '"' -f2)
  PORT=$(grep -oP '[0-9]+:443' $WORKDIR/docker-compose.yml | cut -d ':' -f1)

  if [ -z "$PORT" ]; then
    echo "❌ Не найден порт"
    return
  fi

  echo ""
  echo "Ссылка:"
  echo "tg://proxy?server=$DOMAIN&port=$PORT&secret=ee${SECRET}636c6f7564666c6172652e636f6d"
}

function show_status() {
  docker ps | grep telemt || echo "Контейнер не запущен"
}

function menu() {
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
    *) echo "❌ Неверный выбор" ;;
  esac
}

while true; do
  menu
  echo ""
  done
