#!/bin/bash

set -euo pipefail

AUTOSYS_VERSION="5.0"
SCRIPT_NAME="$(basename "$0")"

LOG_DIR="/var/log/autosys"
BACKUP_ROOT="/var/backups/autosys"
STATE_FILE="/etc/.autosys-state.conf"
SSH_MAIN="/etc/ssh/sshd_config"
SSH_CONF_DIR="/etc/ssh/sshd_config.d"
DROPIN="$SSH_CONF_DIR/00-autosys.conf"
BLOCK_BEGIN="# === autosys begin ==="
BLOCK_END="# === autosys end ==="
MANAGED_RE="^[[:space:]]*(port|permitrootlogin|maxauthtries|maxsessions|pubkeyauthentication|passwordauthentication|permitemptypasswords|challengeresponseauthentication|usepam|x11forwarding|printmotd|tcpkeepalive|clientaliveinterval|clientalivecountmax|usedns)[[:space:]=]"

TARGET_USER=""
PUBLIC_KEY=""
SET_PASSWORD=false
SKIP_UPDATE=false
EXTRA_PACKAGES=""
DRY_RUN=false
SSH_PORT="22"
PORT_SET=false

MODE="full"
INTERACTIVE=false
TMP_DIR=""
LOG_FILE=""
KEY_FINGERPRINT=""
USER_PASSWORD=""

OS_ID=""
OS_FAMILY=""
OS_NAME=""
OS_VERSION_ID=""
PKG_UPDATE=()
PKG_UPGRADE=()
PKG_INSTALL=()
SSH_SERVICE=""
SSH_CLIENT_PKG=""
SSHD_BIN=""

BACKUP_DIR=""
HAD_CONF_DIR=false
SSH_TOUCHED=0
SSH_RESTARTED=0
SSH_COMMITTED=0

STATE_USER=""
STATE_PORT="22"
STATE_FP=""
STATE_OS=""
STATE_LAST=""

usage() {
    local rc="${1:-0}"
    cat << EOF
Использование: $SCRIPT_NAME [ОПЦИИ]

Опции:
  -u, --user USER         Имя пользователя (будет запрошено, если не указано)
  -k, --key KEY           Публичный SSH-ключ (будет запрошен, если не указан)
  -p, --set-password      Запросить/установить пароль (по умолчанию - нет)
  -e, --extra PKGS        Установить дополнительные пакеты (через запятую)
  -s, --ssh-port PORT     Порт SSH (по умолчанию 22)
  --skip-update           Пропустить обновление системы
  --dry-run               Показать, что будет сделано, без фактических изменений
  -h, --help              Показать эту справку

Примеры:
  $SCRIPT_NAME                                     # Интерактивный режим / меню
  $SCRIPT_NAME -u admin -k "ssh-ed25519 AAAA..."   # Указаны пользователь и ключ
  $SCRIPT_NAME -u dev -k "ssh-rsa AAA..." -p -e vim,git -s 2222

Повторный запуск без аргументов при наличии $STATE_FILE открывает меню.
EOF
    exit "$rc"
}

info() { echo "$*"; }
warn() { echo "ПРЕДУПРЕЖДЕНИЕ: $*" >&2; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] $*"
        return 0
    fi
    "$@"
}

rollback_ssh() {
    echo "ОШИБКА: применение SSH-конфигурации не удалось, выполняется откат..." >&2
    local name
    if [ -f "$BACKUP_DIR/sshd_config" ]; then
        cat "$BACKUP_DIR/sshd_config" > "$SSH_MAIN"
    fi
    rm -f "$DROPIN" "$SSH_CONF_DIR/99-bootstrap.conf"
    for name in 00-autosys.conf 99-bootstrap.conf; do
        if [ -f "$BACKUP_DIR/sshd_config.d/$name" ]; then
            cp -p "$BACKUP_DIR/sshd_config.d/$name" "$SSH_CONF_DIR/$name"
        fi
    done
    if [ "$HAD_CONF_DIR" = false ]; then
        rmdir "$SSH_CONF_DIR" 2>/dev/null
    fi
    if [ -n "$SSHD_BIN" ] && "$SSHD_BIN" -t 2>/dev/null; then
        if [ "$SSH_RESTARTED" -eq 1 ]; then
            systemctl restart "$SSH_SERVICE" 2>/dev/null
            echo "SSH перезапущен с восстановленной конфигурацией." >&2
        fi
    else
        echo "КРИТИЧНО: восстановленная конфигурация не проходит sshd -t. Резервные копии: $BACKUP_DIR" >&2
    fi
}

cleanup() {
    local rc=$?
    trap - EXIT
    set +e
    if [ "$rc" -ne 0 ] && [ "$SSH_TOUCHED" -eq 1 ] && [ "$SSH_COMMITTED" -eq 0 ]; then
        rollback_ssh
    fi
    if [ -n "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Скрипт должен запускаться с правами root!"
    fi
}

require_tty() {
    if [[ ! -t 0 ]]; then
        echo "ОШИБКА: скрипту нужен интерактивный терминал, но stdin не является TTY." >&2
        echo "Вероятно, запуск выполнен через конвейер (curl ... | bash)." >&2
        echo "Скачайте файл и запустите его локально:" >&2
        echo "  curl -fsSLo autosys.sh <URL> && chmod +x autosys.sh && sudo ./autosys.sh" >&2
        echo "Либо передайте все параметры аргументами: -u USER -k \"KEY\" (без -p)." >&2
        exit 1
    fi
}

setup_logging() {
    mkdir -p "$LOG_DIR"
    chmod 750 "$LOG_DIR"
    LOG_FILE="$LOG_DIR/bootstrap_$(date +%Y%m%d_%H%M%S).log"
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

validate_username() {
    if [[ ! "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        echo "ОШИБКА: Недопустимое имя пользователя (a-z, 0-9, _, -; до 32 символов, без цифры в начале)." >&2
        return 1
    fi
    return 0
}

validate_port() {
    if [[ ! "$1" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$1))" -lt 1 ] || [ "$((10#$1))" -gt 65535 ]; then
        echo "ОШИБКА: Порт должен быть числом от 1 до 65535." >&2
        return 1
    fi
    return 0
}

validate_password() {
    local pass="$1"
    if [ "${#pass}" -lt 8 ]; then
        echo "ОШИБКА: Пароль должен содержать минимум 8 символов." >&2
        return 1
    fi
    if ! [[ "$pass" =~ [A-Z] ]] || ! [[ "$pass" =~ [a-z] ]]; then
        echo "ОШИБКА: Пароль должен содержать буквы в разных регистрах." >&2
        return 1
    fi
    if ! [[ "$pass" =~ [0-9] ]]; then
        echo "ОШИБКА: Пароль должен содержать хотя бы одну цифру." >&2
        return 1
    fi
    return 0
}

validate_ssh_key() {
    local key="$1" out
    key="${key//$'\r'/}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    if [ -z "$key" ] || [[ "$key" == *$'\n'* ]]; then
        echo "ОШИБКА: Ожидается ровно одна непустая строка с публичным ключом." >&2
        return 1
    fi
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        if [ "$DRY_RUN" = true ]; then
            warn "ssh-keygen не найден, проверка ключа пропущена (dry-run)."
            PUBLIC_KEY="$key"
            KEY_FINGERPRINT="unverified"
            return 0
        fi
        die "ssh-keygen не найден, проверить ключ невозможно."
    fi
    printf '%s\n' "$key" > "$TMP_DIR/key.pub"
    if ! out=$(ssh-keygen -lf "$TMP_DIR/key.pub" 2>&1); then
        echo "ОШИБКА: ssh-keygen не распознал ключ как валидный публичный SSH-ключ." >&2
        return 1
    fi
    if [[ "$out" == *"(DSA)"* ]]; then
        echo "ОШИБКА: DSA-ключи не поддерживаются." >&2
        return 1
    fi
    KEY_FINGERPRINT="$(awk 'NR==1{print $2}' <<< "$out")"
    PUBLIC_KEY="$key"
    return 0
}

detect_os() {
    if [ ! -f /etc/os-release ]; then
        die "Не удалось определить ОС!"
    fi
    OS_ID="$( . /etc/os-release; echo "${ID:-unknown}" )"
    OS_VERSION_ID="$( . /etc/os-release; echo "${VERSION_ID:-unknown}" )"
    local id_like
    id_like="$( . /etc/os-release; echo "${ID_LIKE:-}" )"

    case "$OS_ID" in
        *redos*|*red-os*)   OS_FAMILY="rhel"; OS_NAME="RedOS" ;;
        *astra*)            OS_FAMILY="debian"; OS_NAME="Astra Linux" ;;
        *altlinux*|alt)     OS_FAMILY="alt"; OS_NAME="ALT Linux" ;;
        debian|ubuntu)      OS_FAMILY="debian"; OS_NAME="Debian/Ubuntu" ;;
        rhel|centos|rocky|almalinux) OS_FAMILY="rhel"; OS_NAME="RHEL/CentOS" ;;
        *)
            OS_NAME="$OS_ID"
            case " $id_like " in
                *" debian "*|*" ubuntu "*)          OS_FAMILY="debian" ;;
                *" rhel "*|*" fedora "*|*" centos "*) OS_FAMILY="rhel" ;;
                *)                                  OS_FAMILY="unknown" ;;
            esac
            ;;
    esac

    local mgr
    case "$OS_FAMILY" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            PKG_UPDATE=(apt-get update)
            PKG_UPGRADE=(apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade)
            PKG_INSTALL=(apt-get install -y)
            SSH_SERVICE="ssh"
            SSH_CLIENT_PKG="openssh-client"
            ;;
        rhel)
            if [ -f /etc/centos-release ] && grep -q "CentOS.*release 7" /etc/centos-release 2>/dev/null; then
                mgr="yum"
            elif command -v dnf >/dev/null 2>&1 && dnf --version >/dev/null 2>&1; then
                mgr="dnf"
            else
                mgr="yum"
            fi
            PKG_UPDATE=("$mgr" makecache)
            PKG_UPGRADE=("$mgr" update -y)
            PKG_INSTALL=("$mgr" install -y)
            SSH_SERVICE="sshd"
            SSH_CLIENT_PKG="openssh-clients"
            ;;
        alt)
            export DEBIAN_FRONTEND=noninteractive
            PKG_UPDATE=(apt-get update)
            PKG_UPGRADE=(apt-get -y upgrade)
            PKG_INSTALL=(apt-get install -y)
            SSH_SERVICE="sshd"
            SSH_CLIENT_PKG="openssh-clients"
            ;;
        *)
            die "Неподдерживаемое семейство ОС: $OS_ID"
            ;;
    esac
    info "Обнаружена ОС: $OS_NAME ($OS_ID $OS_VERSION_ID)"
    info "Семейство: $OS_FAMILY | Пакетный менеджер: ${PKG_INSTALL[0]}"
}

find_sshd() {
    SSHD_BIN=""
    local p
    for p in "$(command -v sshd 2>/dev/null || true)" /usr/sbin/sshd /usr/local/sbin/sshd; do
        if [ -n "$p" ] && [ -x "$p" ]; then
            SSHD_BIN="$p"
            return 0
        fi
    done
    return 0
}

detect_ssh_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        die "systemctl не найден: поддерживаются только системы с systemd."
    fi
    local unit
    for unit in "$SSH_SERVICE" sshd ssh; do
        if systemctl cat "${unit}.service" >/dev/null 2>&1; then
            SSH_SERVICE="$unit"
            return 0
        fi
    done
    return 0
}

check_network() {
    info "Проверка сетевого подключения..."
    local ok=false i
    if command -v ping >/dev/null 2>&1; then
        for i in 1 2 3; do
            if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
                info "  - ping до 8.8.8.8: OK"
                ok=true
                break
            fi
            if ping -c 1 -W 2 debian.org >/dev/null 2>&1; then
                info "  - ping до debian.org: OK"
                ok=true
                break
            fi
            sleep 2
        done
        if [ "$ok" = false ]; then
            warn "Нет выхода в интернет. Некоторые операции могут не работать."
        fi
    fi
    if ! getent hosts google.com >/dev/null 2>&1; then
        warn "DNS-резолвинг не работает. Проверьте /etc/resolv.conf."
    fi
}

ensure_ssh_keygen() {
    if command -v ssh-keygen >/dev/null 2>&1; then
        return 0
    fi
    info "ssh-keygen не найден, установка $SSH_CLIENT_PKG..."
    run "${PKG_UPDATE[@]}" || warn "Не удалось обновить список пакетов."
    run "${PKG_INSTALL[@]}" "$SSH_CLIENT_PKG" || die "Не удалось установить $SSH_CLIENT_PKG."
}

update_system() {
    if [ "$SKIP_UPDATE" = true ]; then
        info "Обновление пропущено (--skip-update)."
        return 0
    fi
    info "=== Обновление системы ==="
    if ! run "${PKG_UPDATE[@]}"; then
        warn "Не удалось обновить список пакетов, обновление пропущено."
        return 0
    fi
    if ! run "${PKG_UPGRADE[@]}"; then
        warn "Обновление пакетов завершилось с ошибкой, продолжаем."
        return 0
    fi
    info "Система успешно обновлена"
}

ensure_base_packages() {
    info "Проверка базовых пакетов (sudo, openssh-server, ssh-keygen)..."
    find_sshd
    local need=()
    if ! command -v sudo >/dev/null 2>&1; then
        need+=(sudo)
    fi
    if [ -z "$SSHD_BIN" ]; then
        need+=(openssh-server)
    fi
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        need+=("$SSH_CLIENT_PKG")
    fi
    if [ "${#need[@]}" -gt 0 ]; then
        info "Установка: ${need[*]}"
        run "${PKG_INSTALL[@]}" "${need[@]}" || die "Не удалось установить базовые пакеты: ${need[*]}"
        find_sshd
    else
        info "Базовые пакеты уже установлены."
    fi
}

install_extra_packages() {
    if [ -z "$EXTRA_PACKAGES" ] && [ "$INTERACTIVE" = true ] && [ "$DRY_RUN" = false ]; then
        read -r -p "Установить дополнительные пакеты (например, vim,htop,git)? Оставьте пустым для пропуска: " EXTRA_PACKAGES
    fi
    if [ -z "$EXTRA_PACKAGES" ]; then
        return 0
    fi
    EXTRA_PACKAGES="${EXTRA_PACKAGES// /,}"
    local raw=() pkgs=() p
    IFS=',' read -ra raw <<< "$EXTRA_PACKAGES"
    for p in "${raw[@]}"; do
        if [ -z "$p" ]; then
            continue
        fi
        if [[ "$p" =~ ^[A-Za-z0-9._+:-]+$ ]]; then
            pkgs+=("$p")
        else
            warn "Недопустимое имя пакета пропущено: $p"
        fi
    done
    if [ "${#pkgs[@]}" -eq 0 ]; then
        return 0
    fi
    info "Установка дополнительных пакетов: ${pkgs[*]}"
    run "${PKG_INSTALL[@]}" "${pkgs[@]}" || warn "Установка дополнительных пакетов завершилась с ошибкой."
}

prompt_password() {
    local p1 p2
    while true; do
        read -r -s -p "Введите пароль для $TARGET_USER: " p1
        echo
        read -r -s -p "Повторите пароль: " p2
        echo
        if [ "$p1" != "$p2" ]; then
            echo "Пароли не совпадают." >&2
        elif validate_password "$p1"; then
            USER_PASSWORD="$p1"
            return 0
        fi
    done
}

prompt_key() {
    local input
    while true; do
        read -r -p "Введите публичный SSH-ключ: " input
        if validate_ssh_key "$input"; then
            return 0
        fi
    done
}

prompt_port() {
    local input
    while true; do
        read -r -p "Введите новый порт SSH: " input
        if validate_port "$input"; then
            SSH_PORT="$((10#$input))"
            return 0
        fi
    done
}

set_password() {
    local user="$1" pass="$2" hash
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Установка пароля для $user"
        return 0
    fi
    if command -v chpasswd >/dev/null 2>&1; then
        printf '%s:%s\n' "$user" "$pass" | chpasswd
    elif printf '%s\n' "$pass" | passwd --stdin "$user" >/dev/null 2>&1; then
        :
    elif command -v python3 >/dev/null 2>&1; then
        hash="$(PW="$pass" python3 -c 'import crypt,os; print(crypt.crypt(os.environ["PW"], crypt.mksalt(crypt.METHOD_SHA512)))')"
        usermod -p "$hash" "$user"
    else
        echo "ОШИБКА: Не удалось установить пароль для $user" >&2
        return 1
    fi
}

get_user_input() {
    if [ -z "$TARGET_USER" ]; then
        while true; do
            read -r -p "Введите имя пользователя: " TARGET_USER
            if validate_username "$TARGET_USER"; then
                break
            fi
        done
    fi
    if [ -z "$PUBLIC_KEY" ]; then
        prompt_key
    else
        validate_ssh_key "$PUBLIC_KEY" || exit 1
    fi
    if [ "$SET_PASSWORD" = false ] && [ "$INTERACTIVE" = true ]; then
        local answer
        read -r -p "Установить пароль для пользователя? (y/N): " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            SET_PASSWORD=true
        fi
    fi
}

user_home() {
    getent passwd "$1" | cut -d: -f6 || true
}

create_or_update_user() {
    info "=== Настройка пользователя: $TARGET_USER ==="
    if id "$TARGET_USER" >/dev/null 2>&1; then
        info "Пользователь уже существует."
    else
        info "Создание нового пользователя..."
        run useradd -m -s /bin/bash "$TARGET_USER" || die "Не удалось создать пользователя"
    fi

    if [ "$SET_PASSWORD" = true ]; then
        prompt_password
        set_password "$TARGET_USER" "$USER_PASSWORD"
        USER_PASSWORD=""
        if [ "$DRY_RUN" = false ]; then
            info "Пароль установлен."
        fi
    fi

    local sudo_group=""
    if getent group sudo >/dev/null 2>&1; then
        sudo_group="sudo"
    elif getent group wheel >/dev/null 2>&1; then
        sudo_group="wheel"
    fi
    if [ -z "$sudo_group" ]; then
        warn "Группы sudo/wheel не найдены."
        return 0
    fi

    local in_group=false
    if id "$TARGET_USER" >/dev/null 2>&1; then
        case " $(id -nG "$TARGET_USER") " in
            *" $sudo_group "*) in_group=true ;;
        esac
    fi
    if [ "$in_group" = true ]; then
        info "Пользователь уже в группе $sudo_group"
    else
        run usermod -aG "$sudo_group" "$TARGET_USER"
        info "Пользователь добавлен в группу $sudo_group"
    fi

    if [ "$OS_FAMILY" = "alt" ] && command -v control >/dev/null 2>&1; then
        run control sudowheel enabled || warn "Не удалось включить sudowheel."
    fi
}

selinux_active() {
    command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]
}

selinux_fix_ssh_dir() {
    local ssh_dir="$1"
    if selinux_active; then
        restorecon -R "$ssh_dir" 2>/dev/null || warn "Не удалось установить контекст SELinux для $ssh_dir."
    fi
}

selinux_allow_port() {
    if [ "$SSH_PORT" = "22" ] || ! selinux_active; then
        return 0
    fi
    if ! command -v semanage >/dev/null 2>&1; then
        warn "SELinux активен, но semanage не найден: порт $SSH_PORT не разрешён (пакет policycoreutils-python-utils)."
        return 0
    fi
    if semanage port -l | awk -v p="$SSH_PORT" '$1=="ssh_port_t"{for(i=3;i<=NF;i++){gsub(",","",$i); if($i==p)f=1}} END{exit !f}'; then
        info "Порт $SSH_PORT уже разрешён для SSH в SELinux."
    else
        semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null \
            || semanage port -m -t ssh_port_t -p tcp "$SSH_PORT" \
            || warn "Не удалось разрешить порт $SSH_PORT в SELinux."
    fi
}

add_ssh_key() {
    local replace="${1:-false}"
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Добавление ключа $KEY_FINGERPRINT в authorized_keys пользователя $TARGET_USER"
        return 0
    fi
    local home_dir group ssh_dir auth_file
    home_dir="$(user_home "$TARGET_USER")"
    [ -n "$home_dir" ] || die "Не удалось определить домашний каталог $TARGET_USER"
    group="$(id -gn "$TARGET_USER")"
    ssh_dir="$home_dir/.ssh"
    auth_file="$ssh_dir/authorized_keys"
    install -d -m 700 -o "$TARGET_USER" -g "$group" "$ssh_dir"
    if [ "$replace" = true ]; then
        printf '%s\n' "$PUBLIC_KEY" > "$auth_file"
    else
        touch "$auth_file"
        if [ -s "$auth_file" ] && [ -n "$(tail -c1 "$auth_file")" ]; then
            echo >> "$auth_file"
        fi
        if ! grep -qxF -- "$PUBLIC_KEY" "$auth_file"; then
            printf '%s\n' "$PUBLIC_KEY" >> "$auth_file"
        fi
    fi
    chmod 600 "$auth_file"
    chown "$TARGET_USER:$group" "$auth_file"
    selinux_fix_ssh_dir "$ssh_dir"
    info "Публичный ключ ($KEY_FINGERPRINT) добавлен в $auth_file"
}

render_ssh_conf() {
    cat << EOF
Port $SSH_PORT
PermitRootLogin prohibit-password
MaxAuthTries 3
MaxSessions 3
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 2
UseDNS no
EOF
}

rewrite_main() {
    awk -v re="$MANAGED_RE" '
        /^# === (autosys begin|Применено скриптом bootstrap) ===$/ { skip=1; next }
        /^# === (autosys end|Конец блока) ===$/ { skip=0; next }
        skip { next }
        /^[[:space:]]*[Mm][Aa][Tt][Cc][Hh][[:space:]]/ { inmatch=1 }
        !inmatch && tolower($0) ~ re { print "# autosys: " $0; next }
        { print }
    ' "$SSH_MAIN" > "$1"
}

ssh_include_supported() {
    if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSH_MAIN" 2>/dev/null; then
        return 0
    fi
    local probe="$TMP_DIR/probe.conf"
    printf 'Include %s/*.conf\n' "$SSH_CONF_DIR" > "$probe"
    "$SSHD_BIN" -t -f "$probe" >/dev/null 2>&1
}

backup_ssh_configs() {
    [ -f "$SSH_MAIN" ] || die "Файл $SSH_MAIN не найден."
    BACKUP_DIR="$BACKUP_ROOT/ssh_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR"
    cp -p "$SSH_MAIN" "$BACKUP_DIR/sshd_config"
    if [ -d "$SSH_CONF_DIR" ]; then
        HAD_CONF_DIR=true
        mkdir -p "$BACKUP_DIR/sshd_config.d"
        cp -a "$SSH_CONF_DIR/." "$BACKUP_DIR/sshd_config.d/"
    fi
    info "Резервные копии SSH-конфигов: $BACKUP_DIR"
}

ensure_authorized_keys() {
    local home_dir
    home_dir="$(user_home "$TARGET_USER")"
    if [ -z "$home_dir" ] || [ ! -s "$home_dir/.ssh/authorized_keys" ]; then
        die "Публичный ключ не найден для $TARGET_USER, а парольная аутентификация отключается. Изменение SSH отменено."
    fi
}

verify_effective() {
    local out ports
    out="$("$SSHD_BIN" -T 2>/dev/null)" || return 1
    grep -qx 'passwordauthentication no' <<< "$out" || return 1
    grep -qx 'pubkeyauthentication yes' <<< "$out" || return 1
    ports="$(awk '$1=="port"{print $2}' <<< "$out" | sort -u | tr '\n' ' ')"
    [ "$ports" = "$SSH_PORT " ]
}

port_listening() {
    command -v ss >/dev/null 2>&1 || return 0
    local i
    for i in 1 2 3 4 5; do
        if ss -ltn 2>/dev/null | awk -v port="$SSH_PORT" '$4 ~ (":" port "$") {f=1} END{exit !f}'; then
            return 0
        fi
        sleep 1
    done
    return 1
}

configure_ssh() {
    info "Настройка SSH (порт $SSH_PORT, отключение паролей)..."
    if [ -z "$SSHD_BIN" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Настройка SSH будет применена после установки openssh-server"
            return 0
        fi
        die "Не найден исполняемый файл sshd."
    fi

    local conf_file="$TMP_DIR/autosys.conf"
    render_ssh_conf > "$conf_file"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Резервные копии SSH-конфигов будут сохранены в $BACKUP_ROOT"
        echo "[DRY-RUN] Применяемые параметры:"
        sed 's/^/[DRY-RUN]   /' "$conf_file"
        echo "[DRY-RUN] Проверка sshd -t, откат при ошибке, перезапуск $SSH_SERVICE"
        return 0
    fi

    ensure_authorized_keys
    ssh-keygen -A >/dev/null 2>&1 || true

    local mode="block"
    if ssh_include_supported; then
        mode="dropin"
    fi
    info "Режим конфигурации: $mode"

    backup_ssh_configs
    SSH_TOUCHED=1

    local stripped="$TMP_DIR/sshd_config.stripped"
    local new="$TMP_DIR/sshd_config.new"
    rewrite_main "$stripped"

    if [ "$mode" = "dropin" ]; then
        mkdir -p "$SSH_CONF_DIR"
        install -m 644 -o root -g root "$conf_file" "$DROPIN"
        rm -f "$SSH_CONF_DIR/99-bootstrap.conf"
        if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$stripped"; then
            cp "$stripped" "$new"
        else
            { echo "Include $SSH_CONF_DIR/*.conf"; cat "$stripped"; } > "$new"
        fi
    else
        { echo "$BLOCK_BEGIN"; cat "$conf_file"; echo "$BLOCK_END"; cat "$stripped"; } > "$new"
    fi
    cat "$new" > "$SSH_MAIN"

    "$SSHD_BIN" -t || die "Неверная конфигурация SSH (sshd -t)."
    verify_effective || die "Эффективная конфигурация sshd не соответствует ожидаемой (порт/парольная аутентификация)."

    selinux_allow_port

    SSH_RESTARTED=1
    systemctl restart "$SSH_SERVICE" || die "Не удалось перезапустить $SSH_SERVICE."
    sleep 1
    systemctl is-active --quiet "$SSH_SERVICE" || die "SSH не запустился."
    port_listening || die "SSH не слушает порт $SSH_PORT после перезапуска."

    SSH_COMMITTED=1
    info "SSH успешно перезапущен на порту $SSH_PORT (парольная аутентификация отключена)."
}

load_state() {
    [ -f "$STATE_FILE" ] || return 0
    local k v
    while IFS='=' read -r k v || [ -n "$k" ]; do
        case "$k" in
            TARGET_USER)     STATE_USER="$v" ;;
            SSH_PORT)        STATE_PORT="$v" ;;
            KEY_FINGERPRINT) STATE_FP="$v" ;;
            OS_NAME)         STATE_OS="$v" ;;
            LAST_RUN)        STATE_LAST="$v" ;;
        esac
    done < "$STATE_FILE"
}

save_state() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Сохранение состояния в $STATE_FILE"
        return 0
    fi
    local tmp="$TMP_DIR/state"
    {
        printf 'AUTOSYS_VERSION=%s\n' "$AUTOSYS_VERSION"
        printf 'TARGET_USER=%s\n' "$TARGET_USER"
        printf 'SSH_PORT=%s\n' "$SSH_PORT"
        printf 'KEY_FINGERPRINT=%s\n' "$KEY_FINGERPRINT"
        printf 'OS_NAME=%s\n' "$OS_NAME"
        printf 'LAST_RUN=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$tmp"
    install -m 600 -o root -g root "$tmp" "$STATE_FILE"
}

print_state_summary() {
    local svc="неизвестно"
    if systemctl is-active --quiet "$SSH_SERVICE" 2>/dev/null; then
        svc="активен"
    else
        svc="не активен"
    fi
    echo "=== Текущая конфигурация autosys ==="
    echo "Пользователь:     ${STATE_USER:--}"
    echo "Порт SSH:         ${STATE_PORT:-22}"
    echo "Отпечаток ключа:  ${STATE_FP:--}"
    echo "ОС:               ${STATE_OS:--}"
    echo "Последний запуск: ${STATE_LAST:--}"
    echo "Сервис $SSH_SERVICE:   $svc"
}

print_result() {
    local ip_addr
    ip_addr="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    if [ -z "$ip_addr" ]; then
        ip_addr="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
    echo "=== Настройка успешно завершена ==="
    echo "Лог: $LOG_FILE"
    echo "Пользователь: $TARGET_USER"
    echo "Порт SSH: $SSH_PORT (только ключи)"
    echo "IP-адрес: ${ip_addr:-<адрес сервера>}"
    echo "Подключение: ssh -p $SSH_PORT -i ваш_приватный_ключ $TARGET_USER@${ip_addr:-<адрес сервера>}"
    if [ "$SET_PASSWORD" = true ]; then
        echo "Пароль для sudo был установлен."
    fi
}

menu_update_key() {
    TARGET_USER="$STATE_USER"
    SSH_PORT="$STATE_PORT"
    id "$TARGET_USER" >/dev/null 2>&1 || die "Пользователь $TARGET_USER не существует."
    ensure_ssh_keygen
    prompt_key
    add_ssh_key true
    save_state
    print_result
}

menu_change_port() {
    TARGET_USER="$STATE_USER"
    KEY_FINGERPRINT="$STATE_FP"
    find_sshd
    if [ -z "$SSHD_BIN" ]; then
        die "sshd не установлен. Выберите полную настройку."
    fi
    prompt_port
    configure_ssh
    save_state
    print_result
}

run_menu() {
    load_state
    find_sshd
    detect_ssh_service
    print_state_summary
    local choice
    while true; do
        echo
        echo "1. Обновить ключ"
        echo "2. Сменить порт"
        echo "3. Выполнить полную настройку заново"
        echo "4. Выйти"
        read -r -p "Выбор [1-4]: " choice
        case "$choice" in
            1) menu_update_key; return 0 ;;
            2) menu_change_port; return 0 ;;
            3) MODE="full"; return 0 ;;
            4) exit 0 ;;
            *) echo "Неверный выбор." >&2 ;;
        esac
    done
}

run_full() {
    check_network
    ensure_ssh_keygen
    get_user_input
    update_system
    ensure_base_packages
    detect_ssh_service
    install_extra_packages
    create_or_update_user
    add_ssh_key false
    configure_ssh
    save_state
    print_result
}

parse_args() {
    local opts
    opts="$(getopt -o u:k:pe:s:h --long user:,key:,set-password,extra:,ssh-port:,skip-update,dry-run,help -n "$SCRIPT_NAME" -- "$@")" || usage 1 >&2
    eval set -- "$opts"
    while true; do
        case "$1" in
            -u|--user) TARGET_USER="$2"; shift 2 ;;
            -k|--key) PUBLIC_KEY="$2"; shift 2 ;;
            -p|--set-password) SET_PASSWORD=true; shift ;;
            -e|--extra) EXTRA_PACKAGES="$2"; shift 2 ;;
            -s|--ssh-port) SSH_PORT="$2"; PORT_SET=true; shift 2 ;;
            --skip-update) SKIP_UPDATE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            -h|--help) usage 0 ;;
            --) shift; break ;;
            *) die "Внутренняя ошибка разбора аргументов." ;;
        esac
    done
}

main() {
    parse_args "$@"
    check_root

    if [ -n "$TARGET_USER" ]; then
        validate_username "$TARGET_USER" || exit 1
    fi
    validate_port "$SSH_PORT" || exit 1
    SSH_PORT="$((10#$SSH_PORT))"

    if [ -f "$STATE_FILE" ] && [ -z "$TARGET_USER" ] && [ -z "$PUBLIC_KEY" ] \
        && [ "$PORT_SET" = false ] && [ "$SET_PASSWORD" = false ]; then
        MODE="menu"
        INTERACTIVE=true
    elif [ -z "$TARGET_USER" ] || [ -z "$PUBLIC_KEY" ] || [ "$SET_PASSWORD" = true ]; then
        INTERACTIVE=true
    fi

    if [ "$INTERACTIVE" = true ]; then
        require_tty
    fi

    TMP_DIR="$(mktemp -d)"
    setup_logging
    info "autosys v$AUTOSYS_VERSION"
    detect_os

    if [ "$MODE" = "menu" ]; then
        run_menu
    fi
    if [ "$MODE" = "full" ]; then
        run_full
    fi
}

main "$@"
