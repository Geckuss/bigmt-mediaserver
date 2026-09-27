#!/bin/bash
# CastleLink wrapper entrypoint: injects BepInEx (IL2CPP) into the mounted
# V Rising server volume, then hands off to the original trueosiris start.sh.
set -e

SERVER_DIR="/mnt/vrising/server"
BEPINEX_SRC="/opt/bepinex"

echo "[castlelink] Injecting BepInEx into ${SERVER_DIR} ..."
# The server dir is a bind-mounted volume; steamcmd 'validate' in start.sh keeps
# game files but leaves our added BepInEx files/folders intact. We (re)sync every
# boot so upgrades to the wrapper image propagate.
mkdir -p "${SERVER_DIR}"
cp -f  "${BEPINEX_SRC}/winhttp.dll"          "${SERVER_DIR}/winhttp.dll"
cp -f  "${BEPINEX_SRC}/doorstop_config.ini"  "${SERVER_DIR}/doorstop_config.ini"
cp -rf "${BEPINEX_SRC}/dotnet"               "${SERVER_DIR}/"
# Merge BepInEx tree without clobbering user plugins/config on every boot:
mkdir -p "${SERVER_DIR}/BepInEx"
cp -rf "${BEPINEX_SRC}/BepInEx/core"     "${SERVER_DIR}/BepInEx/"
cp -rf "${BEPINEX_SRC}/BepInEx/patchers" "${SERVER_DIR}/BepInEx/"
# plugins: copy our bundled mod(s) but don't wipe existing ones
mkdir -p "${SERVER_DIR}/BepInEx/plugins" "${SERVER_DIR}/BepInEx/config"
if [ -d "${BEPINEX_SRC}/BepInEx/plugins" ]; then
    cp -rf "${BEPINEX_SRC}/BepInEx/plugins/." "${SERVER_DIR}/BepInEx/plugins/"
fi
# Seed our preconfigured BepInEx.cfg (console disabled for headless) if the
# server doesn't already have one. Without this BepInEx generates a DEFAULT
# config with the console ENABLED, which hangs headless under Wine.
if [ -f "${BEPINEX_SRC}/BepInEx/config/BepInEx.cfg" ] && [ ! -f "${SERVER_DIR}/BepInEx/config/BepInEx.cfg" ]; then
    echo "[castlelink] Seeding BepInEx.cfg (console disabled) ..."
    cp -f "${BEPINEX_SRC}/BepInEx/config/BepInEx.cfg" "${SERVER_DIR}/BepInEx/config/BepInEx.cfg"
fi

# Pre-seed interop assemblies so BepInEx skips generation (Unity base-lib download
# hangs under Wine). Seed both possible folder names (interop = newer, unhollowed =
# older layout) so whichever this BepInEx build expects is populated.
if [ -d /opt/bepinex-interop ]; then
    for d in interop unhollowed; do
        mkdir -p "${SERVER_DIR}/BepInEx/${d}"
        if [ -z "$(ls -A "${SERVER_DIR}/BepInEx/${d}" 2>/dev/null)" ]; then
            echo "[castlelink] Pre-seeding ${SERVER_DIR}/BepInEx/${d} with prebuilt assemblies ..."
            cp -f /opt/bepinex-interop/*.dll "${SERVER_DIR}/BepInEx/${d}/"
        fi
    done
fi

# Wine must load our winhttp.dll (doorstop), not its builtin.
export WINEDLLOVERRIDES="winhttp=n,b"

# NOTE: We do NOT touch Wine here. The base start.sh re-execs itself as the
# 'steam' user (via gosu) and initializes the Wine prefix as that user. Doing
# wine work here (as root) would create a root-owned /root/.wine that the steam
# user can't access. All Wine/CoreCLR service warmup is injected into start.sh
# itself (see Dockerfile sed patch), so it runs as the correct user.

# --- Doorstop environment (READ BY THE WINDOWS winhttp PROXY) ---
# The doorstop_config.ini fallback is unreliable under Wine; the winhttp proxy
# reads these DOORSTOP_* env vars directly. Paths must be Windows-style as seen
# by the game inside Wine. /mnt/vrising/server maps to Wine's Z: drive.
WINPATH='Z:\mnt\vrising\server'
export DOORSTOP_ENABLED=TRUE
export DOORSTOP_TARGET_ASSEMBLY="${WINPATH}\\BepInEx\\core\\BepInEx.Unity.IL2CPP.dll"
export DOORSTOP_IGNORE_DISABLED_ENV=FALSE
export DOORSTOP_MONO_DEBUG_ENABLED=FALSE
export DOORSTOP_MONO_DEBUG_ADDRESS=127.0.0.1:10000
export DOORSTOP_MONO_DEBUG_SUSPEND=FALSE
export DOORSTOP_MONO_DLL_SEARCH_PATH_OVERRIDE=""
export DOORSTOP_CLR_RUNTIME_CORECLR_PATH="${WINPATH}\\dotnet\\coreclr.dll"
export DOORSTOP_CLR_CORLIB_DIR="${WINPATH}\\dotnet"

# --- CoreCLR-under-Wine stability ---
# Disable W^X so CoreCLR's JIT can make pages executable under Wine, and disable
# tiered/server-GC which are known to destabilize CoreCLR under Wine.
export DOTNET_EnableWriteXorExecute=0
export DOTNET_TieredCompilation=0
export DOTNET_gcServer=0

echo "[castlelink] DOTNET_EnableWriteXorExecute=${DOTNET_EnableWriteXorExecute}"
echo "[castlelink] DOORSTOP_TARGET_ASSEMBLY=${DOORSTOP_TARGET_ASSEMBLY}"
echo "[castlelink] WINEDLLOVERRIDES=${WINEDLLOVERRIDES}"
echo "[castlelink] Handing off to /start.sh"
exec /start.sh

