#!/bin/sh

API_URL="https://api.github.com/repos/shtorm-7/sing-box-extended/releases?per_page=30"
ARCHIVE_NAME="sing-box-latest.tar.gz"
DEST_FILE="/usr/bin/sing-box"

R="\033[1;31m"
G="\033[1;32m"
Y="\033[1;33m"
C="\033[1;36m"
N="\033[0m"

cleanup() {
    [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
}

restore_previous_binary() {
    [ "$ROLLBACK_READY" = "1" ] || return 1
    [ -s "$BACKUP_FILE" ] || return 1

    rm -f "$DEST_FILE"
    if ! gzip -dc "$BACKUP_FILE" > "$DEST_FILE"; then
        rm -f "$DEST_FILE"
        return 1
    fi

    chmod 0755 "$DEST_FILE" || return 1
    sync
    return 0
}

rollback_and_fail() {
    reason="$1"

    service "$SERVICE_NAME" stop 2>/dev/null || true

    if restore_previous_binary; then
        service "$SERVICE_NAME" start 2>/dev/null || true
        SERVICE_STOPPED=""
        INSTALL_IN_PROGRESS=""
        cleanup
        WORK_DIR=""
        printf "${R}[!] ОШИБКА: %s Предыдущая версия восстановлена.${N}\n" "$reason"
    else
        printf "${R}[!] КРИТИЧЕСКАЯ ОШИБКА: %s${N}\n" "$reason"
        printf "${R}[!] Автоматический rollback не удался. Временные файлы сохранены: %s${N}\n" "$WORK_DIR"
    fi

    exit 1
}

fail() {
    printf "${R}[!] ОШИБКА: %s${N}\n" "$1"
    cleanup
    WORK_DIR=""
    [ "$SERVICE_STOPPED" = "1" ] && service "$SERVICE_NAME" start 2>/dev/null
    exit 1
}

on_interrupt() {
    printf "\n${R}[!] Установка прервана.${N}\n"

    if [ "$INSTALL_IN_PROGRESS" = "1" ]; then
        service "$SERVICE_NAME" stop 2>/dev/null || true
        if restore_previous_binary; then
            service "$SERVICE_NAME" start 2>/dev/null || true
            printf "${Y}[!] Предыдущая версия восстановлена.${N}\n"
            cleanup
        else
            printf "${R}[!] Автоматический rollback не удался. Временные файлы сохранены: %s${N}\n" "$WORK_DIR"
        fi
    else
        [ "$SERVICE_STOPPED" = "1" ] && service "$SERVICE_NAME" start 2>/dev/null
        cleanup
    fi

    exit 1
}

trap 'on_interrupt' INT TERM

if command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL --insecure --connect-timeout 60"
    DOWNLOAD="curl -fsSL --insecure --connect-timeout 60 -o"
elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -qO- --no-check-certificate --timeout=60"
    DOWNLOAD="wget -q --no-check-certificate --timeout=60 -O"
else
    printf "${R}[!] ОШИБКА: Не найден curl или wget.${N}\n"
    exit 1
fi

if [ -f "/opt/etc/init.d/podkop" ] || [ -f "/etc/init.d/podkop" ]; then
    SERVICE_NAME="podkop"
else
    SERVICE_NAME="sing-box"
fi
HOST_ARCH=$(uname -m)

if [ -f "/etc/openwrt_release" ]; then
    DISTRIB_ARCH=$(. /etc/openwrt_release && echo "$DISTRIB_ARCH")
    case "$DISTRIB_ARCH" in
        *mipsel* | *mipsle*) HOST_ARCH="mipsel" ;;
        *mips64el* | *mips64le*) HOST_ARCH="mips64el" ;;
    esac
fi

case $HOST_ARCH in
  aarch64)                ARCH_SUFFIX="arm64" ;;
  armv7*)                 ARCH_SUFFIX="armv7" ;;
  armv6*)                 ARCH_SUFFIX="armv6" ;;
  x86_64)                 ARCH_SUFFIX="amd64" ;;
  i386 | i686)            ARCH_SUFFIX="386" ;;
  mips)                   ARCH_SUFFIX="mips-softfloat" ;;
  mipsel | mipsle)        ARCH_SUFFIX="mipsle-softfloat" ;;
  mips64)                 ARCH_SUFFIX="mips64" ;;
  mips64el | mips64le)    ARCH_SUFFIX="mips64le" ;;
  riscv64)                ARCH_SUFFIX="riscv64" ;;
  s390x)                  ARCH_SUFFIX="s390x" ;;
  *)
    printf "${R}[!] ОШИБКА: Архитектура $HOST_ARCH не поддерживается.${N}\n"
    exit 1
    ;;
esac

CURRENT_VER=""
if [ -f "$DEST_FILE" ]; then
    CURRENT_VER=$("$DEST_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}') || true
fi

printf "${C}[*] Получаю список последних версий...${N}\n"
API_RESPONSE=$($FETCH "$API_URL" 2>/dev/null) || true

if [ -z "$API_RESPONSE" ]; then
    fail "Не удалось подключиться к GitHub API. Проверьте соединение."
fi

RELEASES=$(echo "$API_RESPONSE" \
  | tr ',' '\n' \
  | grep '"tag_name"' \
  | awk -F '"' '{print $4}' \
  | grep -v -i "rc" \
  | grep -v -i "beta" \
  | grep -v -i "alpha" \
  | head -n 10)

if [ -z "$RELEASES" ]; then
    fail "Не удалось получить список стабильных релизов из API."
fi

printf "\n${C}[*] Доступные стабильные версии для установки:${N}\n"
i=1
for tag in $RELEASES; do
    printf "  ${Y}%d)${N} %s\n" "$i" "$tag"
    i=$((i+1))
done
printf "  ${Y}0)${N} Отмена\n"

printf "\n${C}[?] Выберите версию (0-$((i-1))): ${N}"
read -r choice

if [ "$choice" = "0" ]; then
    printf "${G}[*] Установка отменена.${N}\n"
    exit 0
fi

SELECTED_TAG=""
i=1
for tag in $RELEASES; do
    if [ "$choice" = "$i" ]; then
        SELECTED_TAG="$tag"
        break
    fi
    i=$((i+1))
done

if [ -z "$SELECTED_TAG" ]; then
    fail "Неверный выбор. Пожалуйста, введите корректный номер из списка."
fi

SELECTED_VER=$(echo "$SELECTED_TAG" | sed 's/^v//')

printf "\n${C}[*] Текущая: ${Y}${CURRENT_VER:-не установлен}${C} | Выбранная: ${Y}${SELECTED_VER}${N}\n"

if [ -n "$CURRENT_VER" ] && [ "$CURRENT_VER" = "$SELECTED_VER" ]; then
    printf "${Y}[!] Эта версия уже установлена. Выполняю переустановку...${N}\n"
fi

printf "${C}[*] Ищу ссылку на скачивание для версии $SELECTED_TAG...${N}\n"

RELEASE_URL="https://api.github.com/repos/shtorm-7/sing-box-extended/releases/tags/$SELECTED_TAG"
RELEASE_RESPONSE=$($FETCH "$RELEASE_URL" 2>/dev/null) || true

FILE_PATTERN="linux-$ARCH_SUFFIX.tar.gz"

DOWNLOAD_URL=$(echo "$RELEASE_RESPONSE" \
  | tr ',' '\n' \
  | grep "browser_download_url" \
  | grep "$FILE_PATTERN" \
  | head -n 1 \
  | awk -F '"' '{print $4}')

if [ -z "$DOWNLOAD_URL" ]; then
    fail "Файл для архитектуры '$HOST_ARCH' ($ARCH_SUFFIX) не найден в релизе $SELECTED_TAG."
fi

sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

TMP_FREE_KB=$(df -Pk /tmp 2>/dev/null | awk 'NR == 2 {print $4}')
ROOT_FREE_KB=$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 {print $4}')
TMP_FREE_MB=$((${TMP_FREE_KB:-0} / 1024))
ROOT_FREE_MB=$((${ROOT_FREE_KB:-0} / 1024))

printf "\n${C}[?] Где хранить архив и сжатую rollback-копию?${N}\n"
printf "  ${Y}1)${N} /tmp        (RAM,           свободно: ~%d МБ)\n" "$TMP_FREE_MB"
printf "  ${Y}2)${N} $HOME (flash/overlay, свободно: ~%d МБ)\n" "$ROOT_FREE_MB"
printf "${C}[?] Выберите (1-2): ${N}"
read -r loc_choice

case "$loc_choice" in
    1) WORK_DIR="/tmp/sing-box-install" ;;
    2) WORK_DIR="$HOME/sing-box-install_tmp" ;;
    *) fail "Неверный выбор места установки." ;;
esac

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" || fail "Не удалось создать временную директорию."
cd "$WORK_DIR" || fail "Не удалось открыть временную директорию."

BACKUP_FILE="$WORK_DIR/sing-box.rollback.gz"

printf "${C}[*] Скачиваю архив...${N}\n"
$DOWNLOAD "$ARCHIVE_NAME" "$DOWNLOAD_URL" || fail "Не удалось скачать файл."

if [ ! -s "$ARCHIVE_NAME" ]; then
    fail "Скачанный файл пустой."
fi

if ! gzip -t "$ARCHIVE_NAME" 2>/dev/null; then
    fail "Скачанный архив повреждён."
fi

BINARY_MEMBER=$(tar -tzf "$ARCHIVE_NAME" 2>/dev/null \
    | awk '/(^|\/)sing-box$/ {print; exit}')

if [ -z "$BINARY_MEMBER" ]; then
    fail "Бинарник sing-box не найден в архиве."
fi

ROLLBACK_READY=""
if [ -f "$DEST_FILE" ]; then
    printf "${C}[*] Создаю сжатую rollback-копию текущего sing-box...${N}\n"
    if ! gzip -c "$DEST_FILE" > "$BACKUP_FILE"; then
        rm -f "$BACKUP_FILE"
        fail "Не удалось создать rollback-копию. Проверьте свободное место."
    fi

    if ! gzip -t "$BACKUP_FILE" 2>/dev/null; then
        rm -f "$BACKUP_FILE"
        fail "Rollback-копия повреждена."
    fi
    ROLLBACK_READY="1"
fi

WAS_RUNNING=""
if pidof sing-box >/dev/null 2>&1; then
    WAS_RUNNING="1"
fi

printf "${C}[*] Останавливаю сервис $SERVICE_NAME...${N}\n"
SERVICE_STOPPED="1"
service "$SERVICE_NAME" stop 2>/dev/null || true
sleep 2

sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

INSTALL_IN_PROGRESS="1"
rm -f "$DEST_FILE" || rollback_and_fail "Не удалось удалить текущий бинарник."
sync

printf "${C}[*] Извлекаю новый бинарник напрямую в $DEST_FILE...${N}\n"
if ! tar -xOzf "$ARCHIVE_NAME" "$BINARY_MEMBER" > "$DEST_FILE"; then
    rm -f "$DEST_FILE"
    rollback_and_fail "Не удалось извлечь новый бинарник."
fi

chmod 0755 "$DEST_FILE" || rollback_and_fail "Не удалось выставить права на новый бинарник."
sync

NEW_VERSION=$("$DEST_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}') || true

if [ -z "$NEW_VERSION" ]; then
    rollback_and_fail "Новый sing-box не запускается."
fi

if [ "$NEW_VERSION" != "$SELECTED_VER" ]; then
    rollback_and_fail "Версия установленного бинарника ($NEW_VERSION) не совпадает с выбранной ($SELECTED_VER)."
fi

printf "${C}[*] Запускаю сервис $SERVICE_NAME...${N}\n"
if ! service "$SERVICE_NAME" start; then
    rollback_and_fail "Сервис $SERVICE_NAME не запустился с новой версией."
fi
SERVICE_STOPPED=""

sleep 3
if [ "$WAS_RUNNING" = "1" ] && ! pidof sing-box >/dev/null 2>&1; then
    rollback_and_fail "Процесс sing-box не появился после запуска $SERVICE_NAME."
fi

INSTALL_IN_PROGRESS=""
cd /
cleanup
WORK_DIR=""

printf "${G}[+] Готово: ${Y}${CURRENT_VER:-н/д}${G} -> ${Y}${NEW_VERSION}${N}\n"
