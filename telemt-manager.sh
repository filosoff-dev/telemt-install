#!/usr/bin/env bash
set -Eeuo pipefail

WORKDIR="/opt/telemt"
STATE_FILE="$WORKDIR/telemt.env"
DOCKER_COMPOSE_CMD=()
APT_UPDATED=0
SELF_COPY="${SELF_COPY:-}"
LAST_STEP="запуск скрипта"
LAST_HINT="Повторите команду и проверьте вводимые значения."
MENU_BACK="__MENU_BACK__"
EXIT_TO_SHELL_CODE=10
export DEBIAN_FRONTEND=noninteractive

if [[ -t 1 ]]; then
  COLOR_RESET=$'\033[0m'
  COLOR_BOLD=$'\033[1m'
  COLOR_RED=$'\033[1;31m'
  COLOR_CYAN=$'\033[1;36m'
  COLOR_GREEN=$'\033[1;32m'
  COLOR_YELLOW=$'\033[1;33m'
else
  COLOR_RESET=""
  COLOR_BOLD=""
  COLOR_RED=""
  COLOR_CYAN=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
fi

cleanup_temp_files() {
  if [[ -n "${TMP_GPG_FILE:-}" && -f "${TMP_GPG_FILE:-}" ]]; then
    rm -f "$TMP_GPG_FILE"
  fi

  if [[ -n "${SELF_COPY:-}" && -f "${SELF_COPY:-}" ]]; then
    rm -f "$SELF_COPY"
  fi
}

trap cleanup_temp_files EXIT

set_step() {
  LAST_STEP="$1"
  LAST_HINT="$2"
}

handle_error() {
  local exit_code="$1"
  local line_no="$2"
  local failed_command="$3"

  if [[ "$exit_code" -eq "$EXIT_TO_SHELL_CODE" ]]; then
    return
  fi

  echo "❌ Ошибка на этапе: $LAST_STEP" >&2
  echo "Команда: $failed_command" >&2
  echo "Строка: $line_no" >&2
  echo "Что сделать: $LAST_HINT" >&2
  exit "$exit_code"
}

trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR

is_menu_back() {
  [[ "${1:-}" == "$MENU_BACK" ]]
}

is_confirm_yes() {
  local value="${1:-}"
  value="${value//[$'\r\n\t ']}"
  value="${value,,}"
  [[ "$value" =~ ^(y|yes)$ ]]
}

log() {
  echo "== $1 =="
}

warn() {
  echo "⚠ $1" >&2
}

fail() {
  echo "❌ $1" >&2
  exit 1
}

require_root() {
  set_step "проверка прав доступа" "Запустите скрипт через sudo или под root."

  if [[ "${EUID}" -eq 0 ]]; then
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    echo "Требуются права root, перезапускаем через sudo..."
    SELF_COPY="$(mktemp /tmp/telemt-manager.XXXXXX.sh)"
    cat "${BASH_SOURCE[0]}" > "$SELF_COPY"
    chmod 700 "$SELF_COPY"
    export SELF_COPY
    exec sudo -E bash "$SELF_COPY" "$@"
  fi

  fail "Запустите скрипт от root или установите sudo"
}

require_ubuntu() {
  set_step "проверка операционной системы" "Запустите скрипт на Ubuntu 24.04."

  if [[ ! -r /etc/os-release ]]; then
    fail "Не удалось определить операционную систему"
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  [[ "${ID:-}" == "ubuntu" ]] || fail "Скрипт рассчитан на Ubuntu"
  [[ "${VERSION_ID:-}" == "24.04" ]] || warn "Скрипт рассчитан на Ubuntu 24.04, обнаружена ${PRETTY_NAME:-неизвестная система}"
}

apt_update_once() {
  set_step "обновление списка пакетов" "Проверьте интернет, DNS и доступность репозиториев Ubuntu, затем повторите попытку."

  if [[ "$APT_UPDATED" -eq 0 ]]; then
    apt-get update
    APT_UPDATED=1
  fi
}

ensure_packages() {
  local packages=()
  local package

  for package in "$@"; do
    if ! dpkg -s "$package" >/dev/null 2>&1; then
      packages+=("$package")
    fi
  done

  if [[ "${#packages[@]}" -eq 0 ]]; then
    return
  fi

  log "Установка системных пакетов: ${packages[*]}"
  set_step "установка системных пакетов" "Проверьте интернет, DNS и повторите попытку."
  apt_update_once
  apt-get install -y --no-install-recommends "${packages[@]}"
}

bootstrap_base_system() {
  ensure_packages apt-transport-https ca-certificates curl gnupg iproute2 openssl
}

validate_domain_syntax() {
  local domain="$1"
  local label

  [[ "${#domain}" -le 253 ]] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" != .* && "$domain" != *. ]] || return 1
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$domain" != *..* ]] || return 1

  IFS='.' read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ -n "$label" && "${#label}" -le 63 ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done

  return 0
}

get_public_ipv4() {
  local ip
  set_step "определение публичного IPv4" "Проверьте доступ сервера в интернет и попробуйте снова."
  ip="$(curl -4 -fsSL --max-time 10 https://api.ipify.org)" || return 1
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  printf '%s\n' "$ip"
}

get_public_ipv6() {
  local ip
  set_step "определение публичного IPv6" "Проверьте доступ сервера в интернет или продолжайте без IPv6."
  ip="$(curl -6 -fsSL --max-time 10 https://api64.ipify.org)" || return 1
  [[ "$ip" == *:* ]] || return 1
  printf '%s\n' "$ip"
}

domain_resolves() {
  local domain="$1"
  getent ahostsv4 "$domain" >/dev/null 2>&1 || getent ahostsv6 "$domain" >/dev/null 2>&1
}

domain_points_to_server() {
  local domain="$1"
  local public_ipv4="" public_ipv6=""
  local -a resolved_ipv4=() resolved_ipv6=()
  local ip

  mapfile -t resolved_ipv4 < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
  mapfile -t resolved_ipv6 < <(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)

  if [[ "${#resolved_ipv4[@]}" -eq 0 && "${#resolved_ipv6[@]}" -eq 0 ]]; then
    return 1
  fi

  public_ipv4="$(get_public_ipv4 2>/dev/null || true)"
  public_ipv6="$(get_public_ipv6 2>/dev/null || true)"

  if [[ -n "$public_ipv4" ]]; then
    for ip in "${resolved_ipv4[@]}"; do
      [[ "$ip" == "$public_ipv4" ]] && return 0
    done
  fi

  if [[ -n "$public_ipv6" ]]; then
    for ip in "${resolved_ipv6[@]}"; do
      [[ "$ip" == "$public_ipv6" ]] && return 0
    done
  fi

  return 1
}

detect_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD=(docker compose)
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD=(docker-compose)
    return
  fi

  fail "Docker Compose не найден. Установите compose plugin или docker-compose"
}

run_compose() {
  detect_compose_cmd
  "${DOCKER_COMPOSE_CMD[@]}" "$@"
}

docker_installed() {
  command -v docker >/dev/null 2>&1
}

install_docker() {
  bootstrap_base_system

  if docker_installed; then
    if docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; then
      echo "✔ Docker уже установлен"
      detect_compose_cmd
      return
    fi

    warn "Docker найден, но Compose отсутствует. Доустанавливаем компоненты Docker."
  fi

  log "Установка Docker (официальный репозиторий)"
  set_step "загрузка ключа Docker" "Проверьте интернет и доступность download.docker.com, затем повторите попытку."

  install -m 0755 -d /etc/apt/keyrings

  TMP_GPG_FILE="$(mktemp)"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$TMP_GPG_FILE"
  gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg "$TMP_GPG_FILE"
  chmod a+r /etc/apt/keyrings/docker.gpg

  local arch codename repo_line
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  repo_line="deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable"
  echo "$repo_line" > /etc/apt/sources.list.d/docker.list

  APT_UPDATED=0
  set_step "установка Docker" "Проверьте репозиторий Docker, интернет и повторите попытку."
  apt_update_once
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  set_step "запуск сервиса Docker" "Проверьте systemctl status docker и повторите попытку."
  systemctl enable docker
  systemctl start docker

  detect_compose_cmd
  echo "✔ Docker установлен"
}

ensure_docker_running() {
  set_step "проверка Docker" "Проверьте systemctl status docker и docker info."

  if ! systemctl is-active --quiet docker; then
    echo "Перезапуск Docker..."
    systemctl restart docker
    sleep 3
  fi

  docker info >/dev/null 2>&1 || fail "Docker не отвечает после запуска"
}

validate_port() {
  local port="$1"

  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 )) || return 1

  return 0
}

port_in_use() {
  local port="$1"
  ss -tulpn | grep -q ":${port}[[:space:]]"
}

get_public_ip() {
  local ip
  ip="$(get_public_ipv4)" || return 1
  printf '%s\n' "$ip"
}

prompt_mode() {
  local mode

  echo "" >&2
  echo "1) Использовать домен" >&2
  echo "2) Использовать IP" >&2

  while true; do
    read -r -p "Выбор (1/2): " mode
    mode="${mode//[$'\r\n\t ']}"

    if [[ "$mode" == "*" ]]; then
      printf '%s\n' "$MENU_BACK"
      return
    fi

    case "$mode" in
      1|2)
        printf '%s\n' "$mode"
        return
        ;;
      *)
        warn "Ошибка: введите 1 или 2. Повторите выбор или нажмите * для возврата в главное меню."
        ;;
    esac
  done
}

prompt_domain() {
  local domain

  while true; do
    read -r -p "Введите домен: " domain
    domain="${domain//[$'\r\n\t ']}"
    domain="${domain,,}"

    if [[ "$domain" == "*" ]]; then
      printf '%s\n' "$MENU_BACK"
      return
    fi

    if [[ -z "$domain" || "$domain" == *"/"* || "$domain" == *":"* ]]; then
      warn "Ошибка: введите домен без протокола, слешей и порта. Введите домен еще раз или нажмите * для возврата в главное меню."
      continue
    fi

    if ! validate_domain_syntax "$domain"; then
      warn "Ошибка: домен выглядит некорректным. Проверьте написание и введите домен еще раз или нажмите * для возврата в главное меню."
      continue
    fi

    echo "Проверяем DNS для $domain..." >&2
    if ! domain_resolves "$domain"; then
      warn "Ошибка: домен не резолвится в DNS. Проверьте DNS-записи и введите домен еще раз или нажмите * для возврата в главное меню."
      continue
    fi

    echo "Проверяем, что домен указывает на этот сервер..." >&2
    if ! domain_points_to_server "$domain"; then
      warn "Ошибка: домен не указывает на текущий VPS. Исправьте A/AAAA запись и введите домен еще раз или нажмите * для возврата в главное меню."
      continue
    fi

    echo "✔ Домен прошёл проверку" >&2
    printf '%s\n' "$domain"
    return
  done
}

prompt_port() {
  local current_port="${1:-}"
  local port

  echo "" >&2
  echo "Рекомендуемые порты:" >&2
  echo "2053 2083 2087 2096 8443" >&2

  while true; do
    if [[ -n "$current_port" ]]; then
      read -r -p "Порт [$current_port]: " port
      port="${port//[$'\r\n\t ']}"
      if [[ "$port" == "*" ]]; then
        printf '%s\n' "$MENU_BACK"
        return
      fi
      if [[ -z "$port" ]]; then
        echo "✔ Используем сохранённый порт $current_port" >&2
        printf '%s\n' "$current_port"
        return
      fi
    else
      read -r -p "Порт: " port
      port="${port//[$'\r\n\t ']}"
      if [[ "$port" == "*" ]]; then
        printf '%s\n' "$MENU_BACK"
        return
      fi
    fi

    if ! validate_port "$port"; then
      warn "Ошибка: введите число от 1 до 65535. Введите порт еще раз или нажмите * для возврата в главное меню."
      continue
    fi

    if [[ -n "$current_port" && "$port" == "$current_port" ]]; then
      echo "✔ Используем сохранённый порт $port" >&2
      printf '%s\n' "$port"
      return
    fi

    if port_in_use "$port"; then
      warn "Ошибка: порт $port уже занят. Выберите другой порт и введите его еще раз или нажмите * для возврата в главное меню."
      continue
    fi

    printf '%s\n' "$port"
    return
  done
}

write_config() {
  local domain="$1"
  local secret="$2"

  cat > "$WORKDIR/config.toml" <<EOF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "$domain"

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
main = "$secret"
EOF
}

write_compose() {
  local port="$1"

  cat > "$WORKDIR/docker-compose.yml" <<EOF
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt
    restart: unless-stopped
    ports:
      - "${port}:443"
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
}

write_state() {
  local domain="$1"
  local port="$2"
  local secret="$3"

  cat > "$STATE_FILE" <<EOF
DOMAIN=$(printf '%q' "$domain")
PORT=$(printf '%q' "$port")
SECRET=$(printf '%q' "$secret")
EOF
}

load_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    return 1
  fi

  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [[ -n "${DOMAIN:-}" && -n "${PORT:-}" && -n "${SECRET:-}" ]]
}

show_proxy_link_from_values() {
  local domain="$1"
  local port="$2"
  local secret="$3"
  local proxy_link

  proxy_link="tg://proxy?server=${domain}&port=${port}&secret=ee${secret}636c6f7564666c6172652e636f6d"

  echo ""
  echo "${COLOR_GREEN}${COLOR_BOLD}===== РЕЗУЛЬТАТ =====${COLOR_RESET}"
  echo "${COLOR_CYAN}${COLOR_BOLD}Ссылка для Telegram:${COLOR_RESET}"
  echo "${COLOR_CYAN}$proxy_link${COLOR_RESET}"
  echo ""
  echo "${COLOR_YELLOW}${COLOR_BOLD}Инструкция:${COLOR_RESET}"
  echo "${COLOR_YELLOW}Скопируйте эту ссылку и откройте ее через приложение Telegram, прокси запустится автоматически.${COLOR_RESET}"
}

install_telemt() {
  log "Установка / Обновление TELEMT"

  local mode domain port secret current_port=""
  set_step "подготовка окружения" "Проверьте базовые системные пакеты и повторите попытку."
  bootstrap_base_system
  mode="$(prompt_mode)"
  if is_menu_back "$mode"; then
    echo "Возврат в главное меню..."
    return 0
  fi

  if [[ "$mode" == "1" ]]; then
    domain="$(prompt_domain)"
    if is_menu_back "$domain"; then
      echo "Возврат в главное меню..."
      return 0
    fi
  else
    echo "Определяем IP..."
    domain="$(get_public_ip)" || fail "Не удалось определить публичный IP"
    echo "✔ $domain"
  fi

  install_docker
  ensure_docker_running

  set_step "подготовка рабочей директории" "Проверьте права на /opt/telemt и повторите попытку."
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  if load_state; then
    secret="$SECRET"
    current_port="$PORT"
    echo "✔ Используем существующий секрет"
  else
    secret="$(openssl rand -hex 16)"
    echo "✔ Создан новый секрет"
  fi

  port="$(prompt_port "$current_port")"
  if is_menu_back "$port"; then
    echo "Возврат в главное меню..."
    return 0
  fi

  echo "Создаём конфиг..."
  set_step "создание конфигурации TELEMT" "Проверьте права на /opt/telemt и повторите попытку."
  write_config "$domain" "$secret"
  write_compose "$port"
  write_state "$domain" "$port" "$secret"

  echo "Перезапуск TELEMT..."
  set_step "загрузка образа TELEMT" "Проверьте доступ к ghcr.io и повторите попытку."
  docker rm -f telemt >/dev/null 2>&1 || true
  run_compose pull
  set_step "запуск TELEMT" "Проверьте вывод docker logs telemt и повторите попытку."
  run_compose up -d

  echo "Ждём запуск..."
  sleep 5

  set_step "проверка контейнера TELEMT" "Посмотрите docker logs telemt и исправьте конфигурацию или сетевые настройки."
  docker ps --format '{{.Names}}' | grep -qx 'telemt' || {
    docker logs telemt || true
    fail "TELEMT не запустился"
  }

  set_step "проверка прослушивания порта" "Убедитесь, что порт открыт и не занят другим сервисом, затем повторите попытку."
  port_in_use "$port" || {
    docker logs telemt || true
    fail "Порт $port не слушается"
  }

  echo ""
  echo "===== ГОТОВО ====="
  echo "✔ TELEMT работает"
  show_proxy_link_from_values "$domain" "$port" "$secret"
  return "$EXIT_TO_SHELL_CODE"
}

remove_telemt() {
  log "Удаление TELEMT"

  echo "${COLOR_RED}${COLOR_BOLD}Будут удалены:${COLOR_RESET}"
  echo "${COLOR_RED}- контейнер TELEMT${COLOR_RESET}"
  echo "${COLOR_RED}- docker-compose ресурсы TELEMT${COLOR_RESET}"
  echo "${COLOR_RED}- образ ghcr.io/telemt/telemt:latest${COLOR_RESET}"
  echo "${COLOR_RED}- папка $WORKDIR со всеми файлами${COLOR_RESET}"
  echo ""
  echo "${COLOR_GREEN}${COLOR_BOLD}Останутся:${COLOR_RESET}"
  echo "${COLOR_GREEN}- Docker${COLOR_RESET}"
  echo "${COLOR_GREEN}- Docker Compose${COLOR_RESET}"
  echo "${COLOR_GREEN}- другие контейнеры, образы и volumes, не относящиеся к TELEMT${COLOR_RESET}"
  echo ""

  local confirm
  read -r -p "Подтвердить удаление? (yes/no): " confirm
  confirm="${confirm//[$'\r\n\t ']}"
  confirm="${confirm,,}"

  if [[ "$confirm" == "*" ]]; then
    echo "Возврат в главное меню..."
    return 0
  fi

  if ! is_confirm_yes "$confirm"; then
    echo "Удаление отменено. Введите yes/y или нажмите * для возврата в главное меню."
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    if [[ -f "$WORKDIR/docker-compose.yml" ]]; then
      (
        cd "$WORKDIR"
        run_compose down --rmi all --volumes --remove-orphans >/dev/null 2>&1 || true
      )
    fi

    docker rm -f telemt >/dev/null 2>&1 || true
    docker image rm -f ghcr.io/telemt/telemt:latest >/dev/null 2>&1 || true
  fi

  rm -rf "$WORKDIR"
  echo "✔ Удалено полностью"
}

show_link() {
  if ! load_state; then
    warn "TELEMT не установлен или файл состояния повреждён"
    return
  fi

  show_proxy_link_from_values "$DOMAIN" "$PORT" "$SECRET"
  return "$EXIT_TO_SHELL_CODE"
}

show_status() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker не установлен"
    return
  fi

  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^telemt[[:space:]]' || echo "❌ TELEMT не запущен"
}

run_menu_action() {
  local action_name="$1"
  local status

  set +e
  ( "$action_name" )
  status=$?
  set -e

  if [[ "$status" -eq "$EXIT_TO_SHELL_CODE" ]]; then
    exit 0
  fi

  if [[ "$status" -ne 0 ]]; then
    echo ""
    echo "Возврат в главное меню..."
  fi
}

main_menu() {
  local choice

  while true; do
    echo ""
    echo "===== TELEMT MANAGER ====="
    echo "Этот скрипт устанавливает TELEMT-прокси на порты Cloudflare."
    echo "Если вам это не подходит, выберите 0) Выход."
    echo ""
    echo "1) Установить / Обновить"
    echo "2) Удалить"
    echo "3) Показать ссылку"
    echo "4) Статус"
    echo "0) Выход"
    echo ""

    read -r -p "Выбор: " choice
    choice="${choice//[$'\r\n\t ']}"

    case "$choice" in
      1) run_menu_action install_telemt ;;
      2) run_menu_action remove_telemt ;;
      3) run_menu_action show_link ;;
      4) run_menu_action show_status ;;
      0) exit 0 ;;
      *) warn "Ошибка: неизвестный пункт меню. Выберите 0, 1, 2, 3 или 4." ;;
    esac
  done
}

require_root "$@"
require_ubuntu
main_menu
