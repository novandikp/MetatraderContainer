#!/bin/bash

# ============================================================
# Multi-Instance MetaTrader 5 Launcher
# No auto-login — user logs in manually via VNC
# Instance count driven by MT5_COUNT env var
# ============================================================

TEMPLATE_PREFIX='/config/template/.wine'
WINEDEBUG='-all'
WINE="wine"
MT5_TEMPLATE="$TEMPLATE_PREFIX/drive_c/Program Files/MetaTrader 5"
MT5_EXEC="$MT5_TEMPLATE/terminal64.exe"
MONO_URL="https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi"
MT5SETUP_URL="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
ACCOUNTS_DIR="/config/accounts"
MT5_COUNT="${MT5_COUNT:-1}"
MASTER_ID="${MASTER_ID:-1}"
SHARED_DIR="/shared"

export WINEDEBUG

echo "========== MT5 Multi-Instance Launcher =========="
echo "[MT5] Count: $MT5_COUNT"

[[ "$MT5_COUNT" =~ ^[0-9]+$ ]] || { echo "[MT5] MT5_COUNT must be a positive integer"; exit 1; }
[ "$MT5_COUNT" -lt 1 ] && { echo "[MT5] MT5_COUNT must be at least 1"; exit 1; }

command -v curl >/dev/null 2>&1  || { echo "curl required"; exit 1; }
command -v $WINE >/dev/null 2>&1 || { echo "wine required";  exit 1; }

cleanup() {
    echo "[MT5] Shutting down..."
    for pid in $(jobs -p); do kill "$pid" 2>/dev/null; done
    wait
    exit 0
}
trap cleanup SIGINT SIGTERM

# ---- STEP 1: Template prefix setup ----
export WINEPREFIX="$TEMPLATE_PREFIX"

if [ ! -e "$WINEPREFIX/drive_c/windows/mono" ]; then
    echo "[1/5] Installing Mono in template..."
    mkdir -p "$WINEPREFIX/drive_c"
    curl -Lso "$WINEPREFIX/drive_c/mono.msi" "$MONO_URL" || {
        echo "[MT5] Mono download failed"; exit 1
    }
    WINEDLLOVERRIDES=mscoree=d $WINE msiexec /i "$WINEPREFIX/drive_c/mono.msi" /qn
    rm -f "$WINEPREFIX/drive_c/mono.msi"
    echo "[1/5] Mono installed"
else
    echo "[1/5] Mono OK"
fi

if [ -f "$MT5_EXEC" ]; then
    echo "[2/5] MT5 template OK"
else
    echo "[2/5] Installing MT5 in template (first run, may take a while)..."
    $WINE reg add "HKEY_CURRENT_USER\\Software\\Wine" /v Version /t REG_SZ /d "win10" /f
    curl -Lso "$WINEPREFIX/drive_c/mt5setup.exe" "$MT5SETUP_URL" || {
        echo "[MT5] Download failed"; exit 1
    }
    $WINE "$WINEPREFIX/drive_c/mt5setup.exe" /auto &
    wait $!
    rm -f "$WINEPREFIX/drive_c/mt5setup.exe"
    if [ ! -f "$MT5_EXEC" ]; then
        echo "[MT5] MT5 installation failed"; exit 1
    fi
    echo "[2/5] MT5 template installed"
fi

# ---- STEP 3: Detect Wine user ----
WINE_USER=$(ls "${TEMPLATE_PREFIX}/drive_c/users/" 2>/dev/null |
    grep -v "Default\|Public\|dosdevices" | head -1)
echo "[3/5] Wine user: ${WINE_USER:-unknown}"

# ---- STEP 4: Launch instances ----
echo "[4/5] Launching $MT5_COUNT instance(s)..."
mkdir -p "$ACCOUNTS_DIR"

# Ensure /shared is writable by the container user
if [ -d "$SHARED_DIR" ]; then
    chmod 777 "$SHARED_DIR" 2>/dev/null || true
fi

for ((i=1; i<=MT5_COUNT; i++)); do
    INSTANCE_ID="mt5-${i}"
    PREFIX="${ACCOUNTS_DIR}/${INSTANCE_ID}/.wine"
    TERM_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"

    if [ ! -d "$PREFIX/drive_c" ]; then
        echo "[MT5] ${INSTANCE_ID}: copying template..."
        rm -rf "$PREFIX"
        mkdir -p "$(dirname "$PREFIX")"
        cp -a --reflink=auto "$TEMPLATE_PREFIX" "$PREFIX"
    fi

    if [ ! -f "$TERM_EXE" ]; then
        echo "[MT5] ${INSTANCE_ID}: template not found at $TERM_EXE, skipping"
        continue
    fi

    export WINEPREFIX="$PREFIX"

    ln -sfn "$SHARED_DIR" "${PREFIX}/drive_c/shared"

    if [ -n "$WINE_USER" ]; then
        COMMON_PATH="${PREFIX}/drive_c/users/${WINE_USER}/AppData/Roaming/MetaQuotes/Terminal/Common/Files"
        mkdir -p "$SHARED_DIR/files" 2>/dev/null || true
        rm -rf "$COMMON_PATH"
        ln -sfn "$SHARED_DIR/files" "$COMMON_PATH"
    fi

    mkdir -p "${PREFIX}/drive_c/Program Files/MetaTrader 5/MQL5/Experts" 2>/dev/null || true
    cp "$SHARED_DIR"/ea/*.mq5 "$SHARED_DIR"/ea/*.ex5 \
       "${PREFIX}/drive_c/Program Files/MetaTrader 5/MQL5/Experts/" \
       2>/dev/null || true

    if [ "$i" -eq "$MASTER_ID" ]; then
        mkdir -p /config/signals 2>/dev/null || true
        touch /config/signals/master 2>/dev/null || true
    fi

    $WINE "$TERM_EXE" &
    PID=$!
    echo $PID > "/tmp/${INSTANCE_ID}.pid"
    echo "[MT5] ${INSTANCE_ID} (PID $PID) launched"
done

# ---- STEP 4: Monitor ----
echo "[5/5] Monitoring ${MT5_COUNT} instance(s)..."
while true; do
    for ((i=1; i<=MT5_COUNT; i++)); do
        INSTANCE_ID="mt5-${i}"
        PREFIX="${ACCOUNTS_DIR}/${INSTANCE_ID}/.wine"
        TERM_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
        PID_FILE="/tmp/${INSTANCE_ID}.pid"

        if [ -f "$PID_FILE" ]; then
            OLD_PID=$(< "$PID_FILE")
            if ! kill -0 "$OLD_PID" 2>/dev/null && [ -f "$TERM_EXE" ]; then
                echo "[MT5] ${INSTANCE_ID} crashed. Restarting..."
                export WINEPREFIX="$PREFIX"
                $WINE "$TERM_EXE" &
                NEW_PID=$!
                echo $NEW_PID > "$PID_FILE"
                echo "[MT5] ${INSTANCE_ID} restarted (PID $NEW_PID)"
            fi
        fi
    done
    sleep 5
done
