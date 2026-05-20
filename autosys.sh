#!/bin/bash
# ver.4.1 - Интерактивная настройка Linux (поддержка CLI)
# Поддерживаемые ОС: Debian 12, Astra Linux, RedOS, ALT Linux, CentOS 7/8/9, RHEL

set -euo pipefail

# --- Глобальные переменные ---
LOG_DIR="/opt/scripts/log"
LOG_FILE="$LOG_DIR/bootstrap_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

SCRIPT_NAME="$(basename "$0")"
VERSION="4.1"

# Флаги по умолчанию
TARGET_USER=""
PUBLIC_KEY=""
SET_PASSWORD=false
SKIP_UPDATE=false
EXTRA_PACKAGES=""
DRY_RUN=false
SSH_PORT="22"

# --- Функция помощи ---
usage() {
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
  $SCRIPT_NAME                                     # Интерактивный режим
  $SCRIPT_NAME -u admin -k "ssh-ed25519 AAAA..."   # Указаны пользователь и ключ
  $SCRIPT_NAME -u dev -k "ssh-rsa AAA..." -p -e vim,git -s 2222
EOF
    exit 0
}

# --- Функции проверок ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ОШИБКА: Скрипт должен запускаться с правами root!" >&2
        exit 1
    fi
}

check_network_enhanced() {
    echo "Проверка сетевого подключения..."
    local success=0
    for i in {1..3}; do
        if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            echo "  - ping до 8.8.8.8: OK"
            success=1
            break
        fi
        if ping -c 1 -W 2 debian.org &>/dev/null; then
            echo "  - ping до debian.org: OK"
            success=1
            break
        fi
        sleep 2
    done
    if [ $success -eq 0 ]; then
        echo "ПРЕДУПРЕЖДЕНИЕ: Нет выхода в интернет. Некоторые операции могут не работать." >&2
        # Не выходим, но предупреждаем
    fi
    # Проверка DNS
    if ! nslookup google.com &>/dev/null && ! host google.com &>/dev/null; then
        echo "ПРЕДУПРЕЖДЕНИЕ: DNS резолвинг не работает. Добавляем nameserver 8.8.8.8 временно." >&2
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
    fi
}

validate_password() {
    local pass="$1"
    if [ ${#pass} -lt 8 ]; then
        echo "ОШИБКА: Пароль должен содержать минимум 8 символов." >&2
        return 1
    fi
    if ! [[ "$pass" =~ [A-Z] ]] && ! [[ "$pass" =~ [a-z] ]]; then
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
    local key="$1"
    # Поддерживаемые типы: ssh-rsa, ssh-ed25519, ecdsa-sha2-nistp256
    if [[ "$key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256)[[:space:]]+([A-Za-z0-9+/=]+)[[:space:]]*(.*)$ ]]; then
        return 0
    else
        echo "ОШИБКА: Неверный формат SSH-ключа. Ожидается: ssh-rsa AAAA... или ssh-ed25519 AAAA..." >&2
        return 1
    fi
}

# --- Функции для ОС ---
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION_ID="${VERSION_ID}"
    else
        echo "ОШИБКА: Не удалось определить ОС!" >&2
        exit 1
    fi
    case "$OS_ID" in
        *redos*)        OS_FAMILY="rhel"; OS_NAME="RedOS" ;;
        *astra*)        OS_FAMILY="debian"; OS_NAME="Astra Linux" ;;
        *altlinux*)     OS_FAMILY="alt"; OS_NAME="ALT Linux" ;;
        debian|ubuntu)  OS_FAMILY="debian"; OS_NAME="Debian/Ubuntu" ;;
        rhel|centos|rocky|almalinux) OS_FAMILY="rhel"; OS_NAME="RHEL/CentOS" ;;
        *)              OS_FAMILY="unknown"; OS_NAME="$OS_ID" ;;
    esac

    case "$OS_FAMILY" in
        debian)
            PKG_MANAGER="apt-get"
            UPDATE_CMD="update"
            UPGRADE_CMD="upgrade -y -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\""
            INSTALL_CMD="install -y"
            SSH_SERVICE="ssh"
            ;;
        rhel)
            if [ -f /etc/centos-release ] && grep -q "CentOS.*release 7" /etc/centos-release 2>/dev/null; then
                PKG_MANAGER="yum"
            elif command -v dnf &>/dev/null && dnf --version &>/dev/null; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            UPDATE_CMD="makecache"
            UPGRADE_CMD="update -y"
            INSTALL_CMD="install -y"
            SSH_SERVICE="sshd"
            ;;
        alt)
            PKG_MANAGER="apt-get"
            UPDATE_CMD="update"
            UPGRADE_CMD="upgrade -y"
            INSTALL_CMD="install -y"
            SSH_SERVICE="sshd"
            ;;
        *)
            echo "ОШИБКА: Неподдерживаемое семейство ОС: $OS_FAMILY" >&2
            exit 1
            ;;
    esac
    echo "Обнаружена ОС: $OS_NAME ($OS_ID $OS_VERSION_ID)"
    echo "Семейство: $OS_FAMILY | Пакетный менеджер: $PKG_MANAGER | SSH-сервис: $SSH_SERVICE"
}

# --- Функции установки/обновления ---
update_system() {
    if [ "$SKIP_UPDATE" = true ]; then
        echo "Обновление пропущено (--skip-update)."
        return 0
    fi
    echo "=== Обновление системы ==="
    case "$OS_FAMILY" in
        debian|alt)
            export DEBIAN_FRONTEND=noninteractive
            $PKG_MANAGER $UPDATE_CMD -y || { echo "Предупреждение: не удалось обновить список пакетов"; return 1; }
            $PKG_MANAGER $UPGRADE_CMD || { echo "Предупреждение: обновление пакетов завершилось с ошибкой, пропускаем"; return 1; }
            ;;
        rhel)
            $PKG_MANAGER clean all >/dev/null 2>&1
            $PKG_MANAGER $UPDATE_CMD >/dev/null 2>&1 || { echo "Предупреждение: не удалось обновить кэш"; return 1; }
            $PKG_MANAGER $UPGRADE_CMD || { echo "Предупреждение: обновление завершилось с ошибкой, пропускаем"; return 1; }
            ;;
    esac
    echo "Система успешно обновлена"
    return 0
}

install_base_packages() {
    echo "Установка базовых пакетов (sudo, openssh-server)..."
    local need_install=""
    if ! command -v sudo &>/dev/null; then
        need_install="$need_install sudo"
    fi
    if ! systemctl list-unit-files | grep -q "${SSH_SERVICE}.service" && [ ! -f /usr/sbin/sshd ]; then
        need_install="$need_install openssh-server"
    fi
    if [ -n "$need_install" ]; then
        $DRY_RUN && echo "[DRY-RUN] Установка: $need_install" || $PKG_MANAGER $INSTALL_CMD $need_install
    else
        echo "Базовые пакеты уже установлены."
    fi
}

install_extra_packages() {
    if [ -z "$EXTRA_PACKAGES" ]; then
        # Если пакеты не указаны, спросим пользователя
        if [ "$DRY_RUN" = false ]; then
            read -p "Установить дополнительные пакеты (например, vim,htop,git)? Оставьте пустым для пропуска: " EXTRA_PACKAGES
        fi
    fi
    if [ -n "$EXTRA_PACKAGES" ]; then
        # Убираем пробелы и преобразуем запятую в пробел
        local pkgs=$(echo "$EXTRA_PACKAGES" | tr ',' ' ')
        echo "Установка дополнительных пакетов: $pkgs"
        $DRY_RUN && echo "[DRY-RUN] Установка: $pkgs" || $PKG_MANAGER $INSTALL_CMD $pkgs
    fi
}

# --- Функции работы с пользователем ---
set_password() {
    local user="$1"
    local pass="$2"
    if $DRY_RUN; then
        echo "[DRY-RUN] Установка пароля для $user"
        return 0
    fi
    if command -v chpasswd &>/dev/null; then
        echo "$user:$pass" | chpasswd
    elif echo "$pass" | passwd --stdin "$user" 2>/dev/null; then
        :
    elif command -v python3 &>/dev/null; then
        local hash=$(python3 -c "import crypt; print(crypt.crypt('$pass', crypt.mksalt(crypt.METHOD_SHA512)))")
        usermod -p "$hash" "$user"
    else
        echo "ОШИБКА: Не удалось установить пароль для $user" >&2
        return 1
    fi
}

create_or_update_user() {
    echo "=== Настройка пользователя: $TARGET_USER ==="
    local user_exists=false
    if id "$TARGET_USER" &>/dev/null; then
        user_exists=true
        echo "Пользователь уже существует."
    else
        echo "Создание нового пользователя..."
        if $DRY_RUN; then
            echo "[DRY-RUN] useradd -m -s /bin/bash $TARGET_USER"
        else
            useradd -m -s /bin/bash "$TARGET_USER" || { echo "ОШИБКА: не удалось создать пользователя"; exit 1; }
        fi
    fi

    if [ "$SET_PASSWORD" = true ]; then
        local password=""
        while true; do
            read -s -p "Введите пароль для $TARGET_USER: " password
            echo
            read -s -p "Повторите пароль: " password2
            echo
            if [ "$password" != "$password2" ]; then
                echo "Пароли не совпадают."
            elif validate_password "$password"; then
                break
            fi
        done
        if ! $DRY_RUN; then
            set_password "$TARGET_USER" "$password"
            echo "Пароль установлен."
        fi
    else
        # Если пароль не требуется, спросим, нужно ли его установить
        if [ "$user_exists" = true ] && [ "$DRY_RUN" = false ]; then
            read -p "Установить пароль для $TARGET_USER? (y/N): " set_pass
            if [[ "$set_pass" =~ ^[Yy]$ ]]; then
                local password=""
                while true; do
                    read -s -p "Введите пароль для $TARGET_USER: " password
                    echo
                    read -s -p "Повторите пароль: " password2
                    echo
                    if [ "$password" != "$password2" ]; then
                        echo "Пароли не совпадают."
                    elif validate_password "$password"; then
                        break
                    fi
                done
                if ! $DRY_RUN; then
                    set_password "$TARGET_USER" "$password"
                    echo "Пароль установлен."
                fi
            fi
        fi
    fi

    # Добавление в sudo/wheel
    local sudo_group=""
    if getent group sudo >/dev/null 2>&1; then
        sudo_group="sudo"
    elif getent group wheel >/dev/null 2>&1; then
        sudo_group="wheel"
    fi
    if [ -n "$sudo_group" ]; then
        if ! groups "$TARGET_USER" | grep -q "\b$sudo_group\b"; then
            if $DRY_RUN; then
                echo "[DRY-RUN] Добавить $TARGET_USER в группу $sudo_group"
            else
                usermod -aG "$sudo_group" "$TARGET_USER"
                echo "Пользователь добавлен в группу $sudo_group"
            fi
        else
            echo "Пользователь уже в группе $sudo_group"
        fi
    else
        echo "ПРЕДУПРЕЖДЕНИЕ: Группы sudo/wheel не найдены."
    fi
}

add_ssh_key() {
    local home_dir=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    local ssh_dir="$home_dir/.ssh"
    local auth_file="$ssh_dir/authorized_keys"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    echo "$PUBLIC_KEY" > "$auth_file"
    chmod 600 "$auth_file"
    chown -R "$TARGET_USER":"$TARGET_USER" "$ssh_dir"
    echo "Публичный ключ добавлен в $auth_file"
}

# --- Функции настройки SSH ---
backup_ssh_configs() {
    local backup_suffix=".bak.$(date +%Y%m%d_%H%M%S)"
    [ -f /etc/ssh/sshd_config ] && cp /etc/ssh/sshd_config "/etc/ssh/sshd_config$backup_suffix"
    [ -f /etc/ssh/sshd_config.d/99-bootstrap.conf ] && cp /etc/ssh/sshd_config.d/99-bootstrap.conf "/etc/ssh/sshd_config.d/99-bootstrap.conf$backup_suffix"
    echo "Резервные копии SSH-конфигов созданы с суффиксом $backup_suffix"
}

configure_ssh() {
    echo "Настройка SSH (порт $SSH_PORT, отключение паролей)..."

    # Определяем версию OpenSSH
    local sshd_version=$(sshd -V 2>&1 | grep -oP 'OpenSSH_\K[0-9.]+' | head -1)
    local use_include=false
    if [ -n "$sshd_version" ] && [ "$(echo "$sshd_version" | cut -d. -f1)" -ge 8 ] || \
       [ "$(echo "$sshd_version" | cut -d. -f1)" -eq 7 ] && [ "$(echo "$sshd_version" | cut -d. -f2)" -ge 5 ]; then
        use_include=true
    fi

    # Создаём временный файл с безопасными настройками
    local temp_conf=$(mktemp)
    cat > "$temp_conf" << EOF
Port $SSH_PORT
Protocol 2
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

    if $use_include; then
        mkdir -p /etc/ssh/sshd_config.d
        cp "$temp_conf" /etc/ssh/sshd_config.d/99-bootstrap.conf
        chmod 644 /etc/ssh/sshd_config.d/99-bootstrap.conf
        if ! grep -qE '^Include /etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
            echo "Include /etc/ssh/sshd_config.d/*.conf" >> /etc/ssh/sshd_config
        fi
    else
        # Удаляем предыдущие настройки, если они уже есть (по меткам)
        sed -i '/^# === Применено скриптом bootstrap ===/,/^# === Конец блока ===/d' /etc/ssh/sshd_config
        echo "# === Применено скриптом bootstrap ===" >> /etc/ssh/sshd_config
        cat "$temp_conf" >> /etc/ssh/sshd_config
        echo "# === Конец блока ===" >> /etc/ssh/sshd_config
    fi
    rm -f "$temp_conf"

    # Проверка конфигурации
    if ! sshd -t; then
        echo "ОШИБКА: Неверная конфигурация SSH! Восстанавливаем резервные копии."
        # Восстановление из бэкапа (последний)
        local latest_backup=$(ls -t /etc/ssh/sshd_config.bak.* 2>/dev/null | head -1)
        if [ -n "$latest_backup" ]; then
            cp "$latest_backup" /etc/ssh/sshd_config
        fi
        exit 1
    fi

    # Проверка, не заблокируется ли доступ (ключ добавлен?).
    # Для пользователя $TARGET_USER проверяем наличие ключа
    local home_dir=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    if [ ! -f "$home_dir/.ssh/authorized_keys" ] || [ ! -s "$home_dir/.ssh/authorized_keys" ]; then
        echo "КРИТИЧЕСКАЯ ОШИБКА: Публичный ключ не добавлен для $TARGET_USER, а PasswordAuthentication отключается. После перезапуска SSH вы потеряете доступ!" >&2
        echo "Перезапуск SSH отменён. Исправьте ситуацию вручную." >&2
        exit 1
    fi

    if $DRY_RUN; then
        echo "[DRY-RUN] Перезапуск SSH-сервиса ($SSH_SERVICE)"
    else
        systemctl restart "$SSH_SERVICE"
        if systemctl is-active --quiet "$SSH_SERVICE"; then
            echo "SSH успешно перезапущен на порту $SSH_PORT (парольная аутентификация отключена)."
        else
            echo "ОШИБКА: SSH не запустился!" >&2
            exit 1
        fi
    fi
}

# --- Функции SELinux ---
configure_selinux() {
    if command -v getenforce &>/dev/null && [ "$(getenforce)" != "Disabled" ]; then
        echo "SELinux обнаружен. Устанавливаем контекст для .ssh каталога пользователя."
        local home_dir=$(getent passwd "$TARGET_USER" | cut -d: -f6)
        if $DRY_RUN; then
            echo "[DRY-RUN] restorecon -R $home_dir/.ssh"
        else
            restorecon -R "$home_dir/.ssh" 2>/dev/null || echo "Предупреждение: не удалось установить контекст SELinux (возможно, не установлен policy)."
        fi
        # Если порт SSH не 22, разрешаем его
        if [ "$SSH_PORT" != "22" ]; then
            if $DRY_RUN; then
                echo "[DRY-RUN] semanage port -a -t ssh_port_t -p tcp $SSH_PORT"
            else
                if command -v semanage &>/dev/null; then
                    semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null || echo "Порт $SSH_PORT уже разрешён для SSH."
                else
                    echo "Предупреждение: semanage не найден, не могу разрешить порт $SSH_PORT в SELinux."
                fi
            fi
        fi
    else
        echo "SELinux не активен или отсутствует."
    fi
}

# --- Интерактивный ввод ---
get_user_input() {
    if [ -z "$TARGET_USER" ]; then
        echo -n "Введите имя пользователя: "
        read -r TARGET_USER
    fi
    if [ -z "$PUBLIC_KEY" ]; then
        echo -n "Введите публичный SSH-ключ: "
        read -r PUBLIC_KEY
    fi
    if [ "$SET_PASSWORD" = false ]; then
        echo -n "Установить пароль для пользователя? (y/N): "
        read -r set_pass
        if [[ "$set_pass" =~ ^[Yy]$ ]]; then
            SET_PASSWORD=true
        fi
    fi
}

# --- Главная функция ---
main() {
    check_root
    # Обработка аргументов командной строки (getopts long)
    OPTS=$(getopt -o u:k:pe:s:h --long user:,key:,set-password,extra:,ssh-port:,skip-update,dry-run,help -n "$SCRIPT_NAME" -- "$@")
    if [ $? -ne 0 ]; then
        usage
    fi
    eval set -- "$OPTS"
    while true; do
        case "$1" in
            -u|--user) TARGET_USER="$2"; shift 2 ;;
            -k|--key) PUBLIC_KEY="$2"; shift 2 ;;
            -p|--set-password) SET_PASSWORD=true; shift ;;
            -e|--extra) EXTRA_PACKAGES="$2"; shift 2 ;;
            -s|--ssh-port) SSH_PORT="$2"; shift 2 ;;
            --skip-update) SKIP_UPDATE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            -h|--help) usage ;;
            --) shift; break ;;
            *) echo "Внутренняя ошибка!"; exit 1 ;;
        esac
    done

    # Интерактивный ввод недостающих данных
    get_user_input

    # Проверки
    validate_ssh_key "$PUBLIC_KEY"
    check_network_enhanced

    # Основные шаги
    detect_os
    update_system
    install_base_packages
    install_extra_packages
    create_or_update_user
    add_ssh_key
    backup_ssh_configs
    configure_ssh
    configure_selinux

    # Итог
    local ip_addr=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')
    echo "=== Настройка успешно завершена ==="
    echo "Лог: $LOG_FILE"
    echo "Пользователь: $TARGET_USER"
    echo "Порт SSH: $SSH_PORT (только ключи)"
    echo "IP-адрес: $ip_addr"
    echo "Подключение: ssh -p $SSH_PORT -i ваш_приватный_ключ $TARGET_USER@$ip_addr"
    if [ "$SET_PASSWORD" = true ]; then
        echo "Пароль для sudo был установлен (если потребуется)."
    fi
}

main "$@"
