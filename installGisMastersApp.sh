#!/usr/bin/env bash
# intallGisMastersApp.sh — проверка окружения + загрузка ресурсов + диалог редактирования .env + запуск и ожидание контейнеров
set -Eeuo pipefail

# -------------------- Константы --------------------
REQUIRED_DIR="/opt/crg"          # целевой каталог установки; скрипт сам обеспечит запуск из него
REQUIRED_FREE_GB=40              # минимум свободного места (ГБ)
REQUIRED_RAM_GB=32               # минимум ОЗУ (ГБ)
MAX_KERNEL_MAJOR=6               # ядро должно быть НЕ НОВЕЕ 6.8.x (6.9+ и 6.13 — не подходят)
MAX_KERNEL_MINOR=8
EXPECTED_CONTAINERS=8            # ожидаемое количество healthy контейнеров
WAIT_TIMEOUT_SECS=180            # 3 минуты
WAIT_STEP_SECS=5                 # шаг ожидания

REPO_TARBALL_URL="https://github.com/gis-masters/GIS_Platform/archive/refs/heads/main.tar.gz"
REPO_INSTALLER_URL="https://github.com/gis-masters/GIS_Platform_installer/archive/refs/heads/main.tar.gz"

ISSUES=()

# Сообщение при некорректном вводе (по вашей формулировке — оставлено дословно)
ALLOWED_INPUT_MSG='Был некорректный ввод. Допустимые значения кирилицей: Да да д Нет нет н; Латиницей: Yes yes y No no n'

# -------------------- Утилиты --------------------
log()  { printf "%s\n" "$*"; }
ok()   { printf "  [OK] %s\n" "$*"; }
bad()  { printf "  [!!] %s\n" "$*"; }

to_int_mm() { awk -F. '{maj=$1; min=$2; if(min=="") min=0; printf("%d%03d\n", maj, min)}' <<<"$1"; }

kernel_major_minor() {
  local k
  k="$(uname -r | sed 's/[~-].*$//')"   # 6.8.0-… -> 6.8.0
  awk -F. '{printf("%d.%d\n",$1, ($2==""?0:$2))}' <<<"$k"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

check_tcp() { local host="$1" port="$2"; timeout 5 bash -lc "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1; }

http_head() {
  local url="$1" host port=443
  host="$(awk -F/ '{print $3}' <<<"$url")"
  if has_cmd curl; then curl -fsS --head --max-time 5 "$url" >/dev/null 2>&1 && return 0
  elif has_cmd wget; then wget -q --spider --timeout=5 "$url" >/dev/null 2>&1 && return 0
  fi
  check_tcp "$host" "$port"
}

have_fetcher() {
  if has_cmd curl || has_cmd wget; then return 0
  else ISSUES+=("Нет curl/wget для скачивания"); bad "Не найдено curl или wget для скачивания архивов"; return 1
  fi
}

fetch_to_file() {
  local url="$1" out="$2"
  if has_cmd curl; then curl -fsSL "$url" -o "$out"
  else wget -qO "$out" "$url"
  fi
}

lower() { tr '[:upper:]' '[:lower:]'; }

first_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

# -------------------- Да/Нет с жёстким набором допустимых ответов --------------------
ask_yes_no() {
  # Использование: if ask_yes_no "Вопрос?"; then ... # YES  else ... # NO
  local prompt="${1:-Продолжить?}"
  local ans=""
  while true; do
    read -r -p "$prompt [Да/Нет | Yes/No]: " ans || ans=""
    case "$ans" in
      Да|да|д|Yes|yes|y) return 0 ;; # YES
      Нет|нет|н|No|no|n) return 1 ;; # NO
      *) echo "$ALLOWED_INPUT_MSG" ;;
    esac
  done
}

# -------------------- Bootstrap: обеспечить работу в /opt/crg --------------------
bootstrap_target_dir() {
  local script_path script_name script_inside=0 others_exist=0 SUDO=""
  script_path="$(realpath "$0" 2>/dev/null || echo "")"
  script_name="$(basename "${script_path:-installGisMastersApp.sh}")"
  [[ $EUID -ne 0 && -x "$(command -v sudo)" ]] && SUDO="sudo"

  # 1) Каталог существует?
  if [[ ! -d "$REQUIRED_DIR" ]]; then
    echo "Каталог $REQUIRED_DIR не существует."
    if ask_yes_no "Создать $REQUIRED_DIR и выдать права (777)?"; then
      $SUDO mkdir -p "$REQUIRED_DIR"
      $SUDO chmod -R 777 "$REQUIRED_DIR" || true
    else
      echo "Отменено пользователем."; exit 1
    fi
  fi

  # 2) Выдать права 777, если не так
  local perms; perms="$(stat -c '%a' "$REQUIRED_DIR" 2>/dev/null || echo "")"
  if [[ "$perms" != "777" ]]; then
    $SUDO chmod -R 777 "$REQUIRED_DIR" || true
  fi

  # 3) Скрипт уже внутри /opt/crg?
  if [[ -n "$script_path" && "$script_path" == "$REQUIRED_DIR/"* ]]; then script_inside=1; fi

  # 4) Папка пустая (считая «пусто» = либо совсем пусто, либо в ней только этот скрипт)?
  if (( script_inside )); then
    if find "$REQUIRED_DIR" -mindepth 1 -maxdepth 1 ! -samefile "$script_path" -print -quit | grep -q .; then others_exist=1; fi
  else
    if find "$REQUIRED_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then others_exist=1; fi
  fi

  if (( others_exist )); then
    echo "Папка $REQUIRED_DIR существует, но она не пустая."
    if ask_yes_no "Желаете автоматически очистить каталог? (все данные будут утеряны)"; then
      if (( script_inside )); then
        $SUDO find "$REQUIRED_DIR" -mindepth 1 -maxdepth 1 ! -samefile "$script_path" -exec sudo rm -rf {} +
      else
        $SUDO find "$REQUIRED_DIR" -mindepth 1 -maxdepth 1 -exec sudo rm -rf {} +
      fi
      $SUDO chmod -R 777 "$REQUIRED_DIR" || true
    else
      echo "Отменено пользователем."; exit 0
    fi
  fi

  # 5) Если скрипт не в /opt/crg — скопировать и перезапуститься оттуда
  if (( ! script_inside )); then
    local target="$REQUIRED_DIR/$script_name"
    $SUDO cp "$script_path" "$target"
    $SUDO chown "$(id -u)":"$(id -g)" "$target" 2>/dev/null || true
    $SUDO chmod +x "$target"
    echo "[reexec] Перезапускаю установщик из $REQUIRED_DIR..."
    cd "$REQUIRED_DIR" || true
    exec "$target" "$@"
  else
    cd "$REQUIRED_DIR" || true
  fi
}

# -------------------- Проверки --------------------
check_crg_dir() {
  local sd perms
  sd="$(cd "$(dirname "$(realpath "$0")")" && pwd -P)"

  if [[ -d "$REQUIRED_DIR" ]]; then ok "Каталог $REQUIRED_DIR существует"
  else bad "Каталог $REQUIRED_DIR отсутствует"; ISSUES+=("Нет каталога $REQUIRED_DIR"); fi

  if [[ "$sd" == "$REQUIRED_DIR" ]]; then ok "Скрипт расположен в $REQUIRED_DIR"
  else bad "Скрипт расположен не в $REQUIRED_DIR (фактически: $sd)"; ISSUES+=("Скрипт не находится в $REQUIRED_DIR"); fi

  if [[ -d "$REQUIRED_DIR" ]]; then
    perms="$(stat -c '%a' "$REQUIRED_DIR" 2>/dev/null || true)"
    if [[ "$perms" == "777" ]]; then ok "Права на $REQUIRED_DIR: 777"
    else bad "Права на $REQUIRED_DIR: $perms (требуются 777)"; ISSUES+=("Права $REQUIRED_DIR ≠ 777"); fi
  fi
}

check_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
    if [[ "${ID:-}" == "ubuntu" ]]; then ok "ОС: Ubuntu (${PRETTY_NAME:-unknown})"
    else bad "ОС не Ubuntu (нужна Ubuntu)"; ISSUES+=("ОС не Ubuntu"); fi
  else bad "Не удалось определить ОС"; ISSUES+=("Не удалось определить ОС"); fi
}

check_kernel() {
  local mm k_int max_int
  mm="$(kernel_major_minor)"
  k_int="$(to_int_mm "$mm")"
  max_int="$(to_int_mm "${MAX_KERNEL_MAJOR}.${MAX_KERNEL_MINOR}")"
  if [[ "$k_int" -le "$max_int" ]]; then ok "Версия ядра: $(uname -r) (допустимо ≤ ${MAX_KERNEL_MAJOR}.${MAX_KERNEL_MINOR})"
  else bad "Версия ядра: $(uname -r) — слишком новая (допустимо ≤ ${MAX_KERNEL_MAJOR}.${MAX_KERNEL_MINOR})"; ISSUES+=("Ядро > ${MAX_KERNEL_MAJOR}.${MAX_KERNEL_MINOR}"); fi
}

check_ram() {
  local mem_kb required_kb
  mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
  required_kb=$((REQUIRED_RAM_GB * 1024 * 1024))
  if (( mem_kb >= required_kb )); then ok "ОЗУ: $(awk -v kb="$mem_kb" 'BEGIN{printf "%.1f", kb/1024/1024}') ГБ (минимум ${REQUIRED_RAM_GB} ГБ)"
  else bad "ОЗУ недостаточно: $(awk -v kb="$mem_kb" 'BEGIN{printf "%.1f", kb/1024/1024}') ГБ (< ${REQUIRED_RAM_GB} ГБ)"; ISSUES+=("ОЗУ < ${REQUIRED_RAM_GB} ГБ"); fi
}

check_disk() {
  local avail_bytes avail_gb
  avail_bytes=$(df --output=avail -B1 / 2>/dev/null | tail -n1 | tr -dc '0-9')
  if [[ -z "$avail_bytes" ]]; then bad "Не удалось определить свободное место на корневом разделе"; ISSUES+=("Не удалось проверить свободное место"); return; fi
  avail_gb=$(( avail_bytes / 1024 / 1024 / 1024 ))
  if (( avail_gb >= REQUIRED_FREE_GB )); then ok "Свободное место на /: ${avail_gb} ГБ (минимум ${REQUIRED_FREE_GB} ГБ)"
  else bad "Свободное место на /: ${avail_gb} ГБ (< ${REQUIRED_FREE_GB} ГБ)"; ISSUES+=("Свободное место < ${REQUIRED_FREE_GB} ГБ"); fi
}

check_network() {
  local ok_any=0
  if check_tcp 1.1.1.1 443 || check_tcp 8.8.8.8 443; then ok "Общий выход в интернет (TCP/443) доступен"; ok_any=1
  else bad "Нет подтверждения общего выхода в интернет (TCP/443)"; ISSUES+=("Нет общего выхода в интернет"); fi
  if http_head "https://github.com"; then ok "Доступ к GitHub (https://github.com)"
  else bad "Нет доступа к GitHub (https://github.com)"; ISSUES+=("Нет доступа к GitHub"); fi
  if http_head "https://hub.docker.com"; then ok "Доступ к Docker Hub (https://hub.docker.com)"
  else bad "Нет доступа к Docker Hub (https://hub.docker.com)"; ISSUES+=("Нет доступа к Docker Hub"); fi
  (( ok_any == 1 )) || true
}

check_docker() {
  if has_cmd docker; then ok "Docker CLI найден: $(docker --version 2>/dev/null || echo 'версия не определена')"
  else bad "Docker не установлен (не найден бинарь docker)"; ISSUES+=("Нет docker. Инструкция по установке https://docs.docker.com/engine/install/ubuntu/"); fi

  if has_cmd docker && docker info >/dev/null 2>&1; then ok "Docker daemon доступен"
  else bad "Docker daemon недоступен (права/группа docker)"; ISSUES+=("У пользователя не хватает прав для использования docker выполните 'sudo usermod -aG docker $USER' и перезагрузитесь."); fi

  if docker compose version >/dev/null 2>&1; then ok "docker compose (plugin) найден"
  elif has_cmd docker-compose; then ok "docker-compose (standalone) найден: $(docker-compose --version 2>/dev/null || true)"
  else bad "Не найден docker compose (ни plugin, ни standalone)"; ISSUES+=("Нет docker compose. При установке последней версии docker установится автоматически"); fi
}

# -------------------- Docker helpers --------------------
count_healthy() {
  docker ps --filter "health=healthy" --format '{{.ID}}' 2>/dev/null | wc -l | tr -d ' '
}

is_service_healthy() {
  # по имени сервиса/контейнера (частичное совпадение имени)
  local name="$1"
  local cid
  cid="$(docker ps --filter "name=${name}" --format '{{.ID}}' | head -n1)"
  [[ -z "$cid" ]] && return 1
  local st
  st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo "unknown")"
  [[ "$st" == "healthy" ]]
}

wait_for_containers() {
  local start now healthy
  start="$(date +%s)"
  while :; do
    healthy="$(count_healthy)"
    echo "Сейчас включилось $healthy из $EXPECTED_CONTAINERS"
    if (( healthy >= EXPECTED_CONTAINERS )); then
      return 0   # успех
    fi
    now="$(date +%s)"
    if (( now - start >= WAIT_TIMEOUT_SECS )); then
      break      # таймаут
    fi
    sleep "$WAIT_STEP_SECS"
  done

  # Таймаут
  if (( healthy == EXPECTED_CONTAINERS - 1 )); then
    # Проверяем auth-service
    if ! is_service_healthy "auth-service"; then
      return 2   # особый случай: только auth-service не healthy
    fi
  fi
  return 1       # прочие ошибки
}

# -------------------- Выбор и запуск редактора --------------------
choose_editor() {
  # Не используем vim/*vim*
  if [[ -n "${EDITOR:-}" ]] && has_cmd "$EDITOR" && [[ "$EDITOR" != *vim* ]]; then
    printf "%s\n" "$EDITOR"; return
  fi
  if has_cmd nano;  then printf "nano\n";  return; fi
  if has_cmd ed;    then printf "ed\n";    return; fi
  if has_cmd gedit; then printf "gedit\n"; return; fi
  printf "\n"
}

open_editor_blocking() {
  local file="$1"
  local ed; ed="$(choose_editor)"
  if [[ -z "$ed" ]]; then
    bad "Не найден подходящий редактор (nano/ed/gedit). Установите nano: sudo apt-get update && sudo apt-get install -y nano"
    exit 1
  fi
  echo "[info] Открываю файл в редакторе: $ed"
  if [[ "$ed" == "gedit" ]]; then
    gedit --wait "$file"
  else
    "$ed" "$file"
  fi
}

# -------------------- Действия после согласия --------------------
download_and_prepare() {
  local BASE_DIR="$REQUIRED_DIR"
  local TMP_DIR TARBALL
  TMP_DIR="$(mktemp -d)"
  TARBALL="$TMP_DIR/GIS_Platform-main.tar.gz"

  log "[1/4] Скачиваю данные из основного проекта..."
  fetch_to_file "$REPO_TARBALL_URL" "$TARBALL"

  log "[2/4] Извлекаю ресурсы..."
  mkdir -p "$BASE_DIR/assets"
  tar -xzf "$TARBALL" --strip-components=2 -C "$BASE_DIR/assets" GIS_Platform-main/assets
  rm -rf "$TARBALL"

  log "[3/4] Скачиваю дополнительные зависимости для старта..."
  fetch_to_file "$REPO_INSTALLER_URL" "$TARBALL"

  log "[3/4] Извлекаю .env и compose..."
  tar -xzf "$TARBALL" --strip-components=1 -C "$BASE_DIR" GIS_Platform_installer-main/.env_masters_ru_start
  tar -xzf "$TARBALL" --strip-components=1 -C "$BASE_DIR" GIS_Platform_installer-main/gis_masters_ru_start.yml

  log "[3.1/4] Извлекаю каталог scripts/..."
  tar -xzf "$TARBALL" --strip-components=1 -C "$BASE_DIR" GIS_Platform_installer-main/scripts

  # Подготовка окружения
  if [[ -f "$BASE_DIR/.env" ]]; then
    echo "[info] Файл .env уже существует — не перезаписываю."
  else
    mv -f "$BASE_DIR/.env_masters_ru_start" "$BASE_DIR/.env"
    echo "[ok] Создан .env из шаблона .env_masters_ru_start"
  fi

  # Права на всё под /opt/crg
  chmod -R +x "$BASE_DIR" 2>/dev/null || true

  log "[4/4] Уборка..."
  rm -rf "$TMP_DIR"

  echo
  echo "Готово! В каталоге $BASE_DIR появились:"
  echo " - папка assets"
  echo " - папка scripts"
  echo " - файлы: .env, gis_masters_ru_start.yml"
  echo

  # --- helper: единый запуск и ожидание ---
  start_platform() {
    local dir="$1"
    echo "[run] Перехожу в scripts и запускаю run_gis_masters_ru_start.sh ..."
    ( cd "$dir/scripts" && ./run_gis_masters_ru_start.sh )

    echo "[wait] Ожидаю, пока контейнеры включатся (до 3 минут)..."
    while true; do
      if wait_for_containers; then
        HOST_IP="$(first_ip)"
        echo "Установка прошла успешно. Вы можете открыть страницу проекта по ссылке http://$HOST_IP . Либо зарегистрировать свою организацию по ссылке http://$HOST_IP/register"
        exit 0
      else
        case $? in
          2)
            HOST_IP="$(first_ip)"
            echo "Установка прошла успешно. Некорректны переменные для восстановления пароля по email. Остальной функционал работает. Проект: http://$HOST_IP , регистрация: http://$HOST_IP/register . Восстановление пароля недоступно."
            exit 0
            ;;
          *)
            echo "Установка завершена с ошибкой. Обратитесь к издателю за деталями."
            if ask_yes_no "На слабом сервере время включения всех контейнеров может быть больше. Желаете подождать
            ещё 3 минуты? (вы можете отвечать Да столько раз, сколько будет необходимо)"; then
              echo "[wait] Ожидаю еще раз, пока контейнеры станут healthy (до 3 минут)..."
              continue
            else
              echo "Установка прервана пользователем."
              exit 1
            fi
            ;;
        esac
      fi
    done
  }

  # Диалог редактирования .env
  echo "При редактировании .env необходимо указать корректные значения SPRING_MAIL_USERNAME и SPRING_MAIL_PASSWORD."
  echo "При ошибке в переменных платформа будет работать, однако восстановление пароля будет недоступно."
  echo "Подробнее о переменных: https://github.com/gis-masters/GIS_Platform"

  if ask_yes_no "Вы желаете отредактировать файл .env?"; then
    open_editor_blocking "$BASE_DIR/.env"
    if ask_yes_no "Приступить к запуску?"; then
      start_platform "$BASE_DIR"
    else
      exit 0
    fi
  else
    printf "\n\033[1;33m[ВНИМАНИЕ]\033[0m Приложение будет запущено с настройками по умолчанию.\n" >&2
    printf "\033[1;33m[ВНИМАНИЕ]\033[0m Функция восстановления пароля \033[1mнедоступна\033[0m.\n" >&2
    echo "Запуск через 10 секунд… Нажмите Ctrl+C для отмены." >&2
    sleep 10
    start_platform "$BASE_DIR"
  fi
}

# -------------------- Главный поток --------------------
# Всегда первым делом обеспечиваем работу из /opt/crg (создание/очистка/перезапуск)
bootstrap_target_dir "$@"

log "=== Предварительная проверка окружения ==="
check_crg_dir
check_os
check_kernel
check_ram
check_disk
check_network
have_fetcher
check_docker
log "========================================="

if (( ${#ISSUES[@]} == 0 )); then
  echo "Все параметры соответствуют ожидаемым."
  echo "Ваш сервер подходит для установки приложения."
  if ask_yes_no "Начать установку приложения?"; then
    download_and_prepare
  else
    exit 0
  fi
else
  echo
  echo "===== Сводка по системе ====="
  echo "Хост:        $(hostname)"
  echo "Дата:        $(date -R)"
  if [[ -r /etc/os-release ]]; then . /etc/os-release || true; fi
  echo "ОС:          ${PRETTY_NAME:-$(uname -s)}"
  echo "Ядро:        $(uname -r)"
  echo "Архитектура: $(uname -m)"
  echo "CPU (ядер):  $(nproc 2>/dev/null || echo '?')"
  awk '
    /MemTotal:/ {mt=$2}
    /MemFree:/  {mf=$2}
    /SwapTotal:/ {st=$2}
    END{
      printf("ОЗУ всего:  %.1f ГБ\n", mt/1024/1024);
      printf("ОЗУ свободно: %.1f ГБ\n", mf/1024/1024);
      printf("Swap всего: %.1f ГБ\n", st/1024/1024);
    }' /proc/meminfo 2>/dev/null || true
  echo "Диски:"
  df -hT | awk 'NR==1 || /^\/dev\// {print "  "$0}'
  echo "IP адреса:   $(hostname -I 2>/dev/null || echo 'n/a')"
  echo "Скрипт в:    $(cd "$(dirname "$(realpath "$0")")" && pwd -P)"
  if [[ -d "$REQUIRED_DIR" ]]; then
    echo "Права $REQUIRED_DIR: $(stat -c '%a %U:%G' "$REQUIRED_DIR" 2>/dev/null || echo '?')"
    ls -ld "$REQUIRED_DIR" 2>/dev/null || true
  fi
  if has_cmd docker; then
    echo "Docker версии:"
    docker --version 2>/dev/null || true
    docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || true
  fi
  echo "============================="
  echo
  echo "Мастер установки не может двигаться дальше:"
  for i in "${ISSUES[@]}"; do echo " - $i"; done
  exit 1
fi
