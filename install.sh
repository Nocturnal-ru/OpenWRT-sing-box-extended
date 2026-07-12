#!/bin/sh

API_URL="https://api.github.com/repos/shtorm-7/sing-box-extended/releases?per_page=30"
ARCHIVE_NAME="sing-box-latest.tar.gz"
DEST_FILE="/usr/bin/sing-box"

R="\033[1;31m"
G="\033[1;32m"
Y="\033[1;33m"
C="\033[1;36m"
N="\033[0m"

trap 'printf "\n${R}[!] Установка прервана.${N}\n"; [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"; [ "$SERVICE_STOPPED" = "1" ] && service "$SERVICE_NAME" start 2>/dev/null; exit 1' INT TERM

fail() {
    printf "${R}[!] ОШИБКА: %s${N}\n" "$1"
    [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
    [ "$SERVICE_STOPPED" = "1" ] && service "$SERVICE_NAME" start 2>/dev/null
    exit 1
}

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
  | head -n 5)

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

FREE_RAM_KB=$(awk '/MemFree/ {print $2}' /proc/meminfo)
FREE_RAM_MB=$((FREE_RAM_KB / 1024))

printf "\n${C}[?] Куда скачивать и распаковывать?${N}\n"
printf "  ${Y}1)${N} /tmp        (RAM,   свободно: ~%d МБ)\n" "$FREE_RAM_MB"
printf "  ${Y}2)${N} $HOME (flash/overlay)\n"
printf "${C}[?] Выберите (1-2): ${N}"
read -r loc_choice

case "$loc_choice" in
    1) WORK_DIR="/tmp/sing-box-install" ;;
    2) WORK_DIR="$HOME/sing-box-install_tmp" ;;
    *) fail "Неверный выбор места установки." ;;
esac

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

printf "${C}[*] Скачиваю и устанавливаю...${N}\n"
$DOWNLOAD "$ARCHIVE_NAME" "$DOWNLOAD_URL" || fail "Не удалось скачать файл."

if [ ! -s "$ARCHIVE_NAME" ]; then
    fail "Скачанный файл пустой."
fi

SERVICE_STOPPED="1"
service "$SERVICE_NAME" stop 2>/dev/null || true
sleep 2

sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

tar -xzf "$ARCHIVE_NAME" || fail "Не удалось распаковать архив."
rm -f "$ARCHIVE_NAME"

BINARY_PATH=$(find . -type f -name sing-box | head -n 1)

if [ -z "$BINARY_PATH" ]; then
    fail "Бинарник не найден в архиве."
fi

mv -f "$BINARY_PATH" "$DEST_FILE" || fail "Не удалось заменить файл."
chmod +x "$DEST_FILE"

NEW_VERSION=$("$DEST_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}') || true

cd /
rm -rf "$WORK_DIR"
WORK_DIR=""

SERVICE_STOPPED=""
service "$SERVICE_NAME" start

printf "${G}[+] Готово: ${Y}${CURRENT_VER:-н/д}${G} -> ${Y}${NEW_VERSION:-н/д}${N}\n"
