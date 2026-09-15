#!/usr/bin/env bash
#
# configure-new-node.sh
#
# Configuracion completa de un nodo de computo nuevo para un cluster Beowulf
# con interconexion InfiniBand (tarjetas Mellanox ConnectX / driver mlx5),
# pensado para Linux Mint Cinnamon (base Ubuntu).
#
# Uso:
#   sudo ./configure-new-node.sh
#
# El script es interactivo (pregunta nombre de nodo, IP InfiniBand, etc.)
# y esta dividido en etapas idempotentes: se puede volver a ejecutar sobre
# el mismo nodo sin romper nada si algun paso fallo o si se quiere repetir.
#
# Etapas:
#   1) Chequeos previos (root, distro, log)
#   2) Recoleccion de parametros (interactivo)
#   3) Actualizacion del sistema
#   4) Usuario/grupo "ryzen" + autologin (LightDM)
#   5) Estabilidad de Cinnamon (sin bloqueos/suspension/salvapantallas; la
#      interfaz grafica en si NUNCA se desactiva, queda lista para monitoreo)
#   6) Desactivar suspension/hibernacion a nivel de systemd/logind
#   7) Estados C / gobernador de CPU (estabilidad para AMD Ryzen)
#   8) Limites de memoria (memlock, nofile) para RDMA
#   9) Paquetes RDMA/InfiniBand + modulos mlx5 (se detiene y espera input del
#      usuario si no detecta fisicamente la tarjeta)
#  10) Bibliotecas HPC desde paquetes descargados (UCX/libfabric/LibXC/OpenMPI)
#  11) Interfaz IPoIB (ib0) con IP estatica
#  12) /etc/hosts del cluster
#  13) Llaves SSH hacia/desde el nodo master
#  14) Cliente NFS + montaje de /cluster
#  15) (Opcional) registrar el nodo en /etc/exports del master via SSH
#  16) Toolchain MPI/OpenMP (OpenMPI + UCX + build-essential)
#  17) Resumen final
#
set -uo pipefail

# ============================================================================
# 0. Constantes y utilidades
# ============================================================================

SCRIPT_VERSION="1.0.0"
LOG_FILE="/var/log/hpc-node-setup.log"
STATE_DIR="/etc/hpc-cluster"
STATE_FILE="${STATE_DIR}/node.conf"

CLUSTER_USER="ryzen"
CLUSTER_GROUP="ryzen"
SHARED_MOUNT_POINT="/cluster"
IB_NETMASK_CIDR="24"

COLOR_RESET="\e[0m"
COLOR_RED="\e[31m"
COLOR_GREEN="\e[32m"
COLOR_YELLOW="\e[33m"
COLOR_BLUE="\e[34m"
COLOR_BOLD="\e[1m"

STEP_NUM=0
FAILED_STEPS=()
SKIPPED_STEPS=()
SSH_TRUST_OK=false
IB_IFACE=""
IB_CARD_PRESENT=true
DOWNLOADS_DIR=""
DO_CHECK_DOWNLOADS=false
HPC_STACK_PREFIX="/opt/hpc-stack"
UCX_PREFIX=""
LIBFABRIC_PREFIX=""
LIBXC_PREFIX=""
OPENMPI_BUILT_FROM_SOURCE=false

log() {
    local msg="$1"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ${msg}" | tee -a "${LOG_FILE}" >/dev/null
}

info()    { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; log "[INFO] $*"; }
ok()      { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $*";   log "[OK] $*"; }
warn()    { echo -e "${COLOR_YELLOW}[AVISO]${COLOR_RESET} $*"; log "[AVISO] $*"; }
err()     { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*"; log "[ERROR] $*"; }

step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo
    echo -e "${COLOR_BOLD}${COLOR_BLUE}==> Paso ${STEP_NUM}: $*${COLOR_RESET}"
    log "==> Paso ${STEP_NUM}: $*"
}

# Ejecuta una etapa (funcion) capturando errores sin abortar todo el script,
# para que un fallo puntual (p.ej. un paquete no disponible) no impida seguir
# configurando el resto del nodo.
run_stage() {
    local stage_fn="$1"
    local stage_desc="$2"
    if ! "${stage_fn}"; then
        err "La etapa '${stage_desc}' fallo. Revisa ${LOG_FILE}. Continuando con las demas etapas."
        FAILED_STEPS+=("${stage_desc}")
    fi
}

ask() {
    # ask "pregunta" "valor_por_defecto" -> imprime la respuesta por stdout
    local prompt="$1"
    local default="${2:-}"
    local answer
    if [[ -n "${default}" ]]; then
        read -r -p "$(echo -e "${COLOR_YELLOW}?${COLOR_RESET} ${prompt} [${default}]: ")" answer
        echo "${answer:-${default}}"
    else
        while true; do
            read -r -p "$(echo -e "${COLOR_YELLOW}?${COLOR_RESET} ${prompt}: ")" answer
            [[ -n "${answer}" ]] && { echo "${answer}"; return; }
            echo "  (este dato es obligatorio)" >&2
        done
    fi
}

confirm() {
    # confirm "pregunta" [default y/n] -> retorna 0 (si) o 1 (no)
    local prompt="$1"
    local default="${2:-s}"
    local hint="s/n"
    [[ "${default}" == "s" ]] && hint="S/n"
    [[ "${default}" == "n" ]] && hint="s/N"
    local answer
    read -r -p "$(echo -e "${COLOR_YELLOW}?${COLOR_RESET} ${prompt} (${hint}): ")" answer
    answer="${answer:-${default}}"
    [[ "${answer,,}" == "s" || "${answer,,}" == "si" || "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "Este script debe ejecutarse como root (usa: sudo $0)"
        exit 1
    fi
}

backup_file() {
    local f="$1"
    if [[ -f "${f}" && ! -f "${f}.hpc-orig" ]]; then
        cp -a "${f}" "${f}.hpc-orig"
    fi
}

line_in_file_present() {
    local file="$1"
    local pattern="$2"
    [[ -f "${file}" ]] && grep -qF -- "${pattern}" "${file}"
}

append_once() {
    # append_once archivo linea -> agrega la linea si no existe ya
    local file="$1"
    local line="$2"
    if ! line_in_file_present "${file}" "${line}"; then
        echo "${line}" >> "${file}"
    fi
}

pkg_install() {
    # Instala paquetes tolerando que alguno no exista en el repo (distintas
    # versiones de Ubuntu/Mint traen distintos nombres de paquete).
    local pkgs=("$@")
    local ok_pkgs=() bad_pkgs=()
    for p in "${pkgs[@]}"; do
        if apt-cache show "${p}" >/dev/null 2>&1; then
            ok_pkgs+=("${p}")
        else
            bad_pkgs+=("${p}")
        fi
    done
    if [[ ${#bad_pkgs[@]} -gt 0 ]]; then
        warn "Paquetes no encontrados en los repositorios (se omiten): ${bad_pkgs[*]}"
    fi
    if [[ ${#ok_pkgs[@]} -gt 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${ok_pkgs[@]}" 2>&1 | tee -a "${LOG_FILE}"
        return "${PIPESTATUS[0]}"
    fi
    return 0
}

wait_for_ib_card() {
    # Se detiene y espera input del usuario mientras no se detecte
    # fisicamente la tarjeta Mellanox/InfiniBand por PCI, en vez de asumir
    # que no esta y seguir de largo.
    while true; do
        if lspci | grep -qi mellanox; then
            ok "Tarjeta Mellanox detectada por PCI:"
            lspci | grep -i mellanox | tee -a "${LOG_FILE}"
            IB_CARD_PRESENT=true
            return 0
        fi

        warn "No se detecto ninguna tarjeta Mellanox/InfiniBand por PCI (lspci)."
        echo
        echo "  [r] Reintentar deteccion (revisa que la tarjeta este bien asentada en el slot PCIe/riser y con alimentacion, luego reintenta)"
        echo "  [c] Continuar sin InfiniBand (se omitiran los pasos de red IPoIB; el resto del nodo se configura igual)"
        echo "  [a] Abortar la configuracion de este nodo"
        local choice
        choice="$(ask "¿Que deseas hacer?" "r")"
        case "${choice,,}" in
            r|reintentar|retry) continue ;;
            c|continuar|continue) IB_CARD_PRESENT=false; warn "Continuando sin tarjeta InfiniBand detectada."; return 0 ;;
            a|abortar|abort) err "Configuracion abortada por el usuario."; exit 1 ;;
            *) warn "Opcion no reconocida ('${choice}'). Escribe 'r', 'c' o 'a'." ;;
        esac
    done
}

find_downloaded_archive() {
    # find_downloaded_archive <carpeta> <palabra_clave> -> ruta del tarball
    # mas reciente que coincida, o vacio si no hay ninguno.
    local dir="$1" keyword="$2"
    [[ -d "${dir}" ]] || return 0
    find "${dir}" -maxdepth 1 -iname "*${keyword}*" \( -iname "*.tar.gz" -o -iname "*.tar.bz2" -o -iname "*.tar.xz" -o -iname "*.tgz" \) 2>/dev/null | sort | tail -n1
}

build_from_source() {
    # build_from_source <nombre> <tarball> <prefix> [args extra de configure/cmake]
    # Detecta automaticamente si el proyecto usa autotools (./configure) o
    # CMake (CMakeLists.txt) y compila/instala en <prefix>.
    local name="$1" tarball="$2" prefix="$3"; shift 3
    local extra_args=("$@")
    local build_root="/usr/local/src/hpc-build"
    mkdir -p "${build_root}"
    local extract_dir
    extract_dir="$(mktemp -d "${build_root}/${name}.XXXXXX")"

    info "${name}: extrayendo $(basename "${tarball}") en ${extract_dir}..."
    if ! tar -xf "${tarball}" -C "${extract_dir}" --strip-components=1 2>>"${LOG_FILE}"; then
        err "${name}: no se pudo extraer ${tarball}."
        return 1
    fi

    pushd "${extract_dir}" >/dev/null || return 1
    local status=0
    if [[ -x ./configure ]]; then
        info "${name}: configurando (autotools, prefix=${prefix})..."
        ./configure --prefix="${prefix}" "${extra_args[@]}" 2>&1 | tee -a "${LOG_FILE}"; status="${PIPESTATUS[0]}"
        if [[ "${status}" -eq 0 ]]; then
            info "${name}: compilando (make -j$(nproc))..."
            make -j"$(nproc)" 2>&1 | tee -a "${LOG_FILE}"; status="${PIPESTATUS[0]}"
        fi
        if [[ "${status}" -eq 0 ]]; then
            info "${name}: instalando en ${prefix}..."
            make install 2>&1 | tee -a "${LOG_FILE}"; status="${PIPESTATUS[0]}"
        fi
    elif [[ -f ./CMakeLists.txt ]]; then
        info "${name}: configurando (CMake, prefix=${prefix})..."
        mkdir -p build && cd build || { popd >/dev/null; return 1; }
        cmake .. -DCMAKE_INSTALL_PREFIX="${prefix}" "${extra_args[@]}" 2>&1 | tee -a "${LOG_FILE}"; status="${PIPESTATUS[0]}"
        if [[ "${status}" -eq 0 ]]; then
            info "${name}: compilando (make -j$(nproc))..."
            make -j"$(nproc)" 2>&1 | tee -a "${LOG_FILE}"; status="${PIPESTATUS[0]}"
        fi
        if [[ "${status}" -eq 0 ]]; then
            info "${name}: instalando en ${prefix}..."
            make install 2>&1 | tee -a "${LOG_FILE}"; status="${PIPESTATUS[0]}"
        fi
    else
        err "${name}: no se encontro 'configure' ni 'CMakeLists.txt'; no se puede compilar automaticamente."
        popd >/dev/null
        return 1
    fi
    popd >/dev/null
    return "${status}"
}

trap 'err "Interrumpido por el usuario (Ctrl+C)."; exit 130' INT

# ============================================================================
# 1. Chequeos previos
# ============================================================================

preflight() {
    require_root
    mkdir -p "${STATE_DIR}"
    touch "${LOG_FILE}"

    echo -e "${COLOR_BOLD}Configuracion de nodo nuevo para cluster Beowulf/InfiniBand${COLOR_RESET}"
    echo "Version del script: ${SCRIPT_VERSION}"
    echo "Log: ${LOG_FILE}"
    echo

    if [[ ! -f /etc/os-release ]]; then
        err "No se pudo detectar la distribucion (falta /etc/os-release)."
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    info "Distribucion detectada: ${PRETTY_NAME:-desconocida}"
    if [[ "${ID:-}" != "linuxmint" && "${ID_LIKE:-}" != *ubuntu* && "${ID:-}" != "ubuntu" ]]; then
        warn "Esto no parece ser Linux Mint / Ubuntu. El script deberia funcionar en derivados de Debian, pero no esta garantizado."
        confirm "¿Continuar de todos modos?" "n" || exit 1
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        err "No se encontro 'apt-get'. Este script requiere una distribucion basada en Debian/Ubuntu."
        exit 1
    fi
}

# ============================================================================
# 2. Recoleccion interactiva de parametros
# ============================================================================

gather_input() {
    echo
    echo -e "${COLOR_BOLD}--- Datos del nodo ---${COLOR_RESET}"

    local suggested_hostname
    suggested_hostname="$(hostname 2>/dev/null || echo nodo)"

    NODE_NAME="$(ask "Nombre de este nodo (ej: nodo6)" "${suggested_hostname}")"
    NODE_IB_LAST_OCTET="$(ask "Ultimo octeto de la IP InfiniBand de este nodo (10.10.10.X)")"
    while ! [[ "${NODE_IB_LAST_OCTET}" =~ ^[0-9]+$ ]] || (( NODE_IB_LAST_OCTET < 2 || NODE_IB_LAST_OCTET > 254 )); do
        warn "Debe ser un numero entre 2 y 254 (el .1 se reserva normalmente para 'master')."
        NODE_IB_LAST_OCTET="$(ask "Ultimo octeto de la IP InfiniBand de este nodo (10.10.10.X)")"
    done
    NODE_IB_IP="10.10.10.${NODE_IB_LAST_OCTET}"

    MASTER_HOSTNAME="$(ask "Nombre de host del nodo maestro" "master")"
    MASTER_IB_IP="$(ask "IP InfiniBand del nodo maestro" "10.10.10.1")"

    echo
    echo -e "${COLOR_BOLD}--- Recursos remotos ---${COLOR_RESET}"
    NFS_EXPORT_PATH="$(ask "Ruta exportada por NFS en el maestro" "${SHARED_MOUNT_POINT}")"
    NFS_MOUNT_POINT="$(ask "Punto de montaje local para esa carpeta compartida" "${SHARED_MOUNT_POINT}")"

    echo
    echo -e "${COLOR_BOLD}--- Cuenta de trabajo ---${COLOR_RESET}"
    CLUSTER_USER="$(ask "Usuario estandar del cluster" "${CLUSTER_USER}")"
    CLUSTER_GROUP="$(ask "Grupo estandar del cluster" "${CLUSTER_GROUP}")"

    echo
    echo -e "${COLOR_BOLD}--- Opciones ---${COLOR_RESET}"
    DO_APT_UPGRADE=false
    confirm "¿Actualizar todos los paquetes del sistema (apt upgrade) antes de continuar?" "s" && DO_APT_UPGRADE=true

    DO_RYZEN_CSTATE_FIX=false
    confirm "¿Aplicar mitigaciones de estabilidad para congelamientos tipicos de plataformas AMD Ryzen (C-states/gobernador de CPU)?" "s" && DO_RYZEN_CSTATE_FIX=true

    DO_SSH_COPY_TO_MASTER=false
    confirm "¿Intentar copiar la llave SSH de este nodo al maestro ahora (te pedira la contrasena del usuario ${CLUSTER_USER} en ${MASTER_HOSTNAME})?" "s" && DO_SSH_COPY_TO_MASTER=true

    DO_REMOTE_EXPORTS=false
    if [[ "${DO_SSH_COPY_TO_MASTER}" == true ]]; then
        confirm "¿Intentar agregar automaticamente este nodo a /etc/exports del maestro via SSH (requiere sudo en el maestro)?" "n" && DO_REMOTE_EXPORTS=true
    fi

    DO_MOUNT_NFS=true
    confirm "¿Configurar y montar el recurso NFS compartido ahora?" "s" || DO_MOUNT_NFS=false

    echo
    echo -e "${COLOR_BOLD}--- Bibliotecas HPC desde paquetes descargados (opcional) ---${COLOR_RESET}"
    info "Si ya descargaste los .tar.gz/.tar.bz2/.tar.xz de UCX, OpenMPI, libfabric y/o LibXC (suelen ser mas recientes y estables para RDMA que los del repositorio de Mint/Ubuntu), el script puede compilarlos e instalarlos en vez de usar esos paquetes del repositorio."
    DO_CHECK_DOWNLOADS=false
    confirm "¿Buscar esos paquetes descargados y ofrecer compilarlos?" "s" && DO_CHECK_DOWNLOADS=true
    if [[ "${DO_CHECK_DOWNLOADS}" == true ]]; then
        DOWNLOADS_DIR="$(ask "Carpeta donde estan los paquetes descargados" "/home/${CLUSTER_USER}/Descargas")"
    fi

    echo
    echo -e "${COLOR_BOLD}--- Resumen ---${COLOR_RESET}"
    cat <<EOF
  Nodo:                  ${NODE_NAME}
  IP InfiniBand nodo:    ${NODE_IB_IP}/${IB_NETMASK_CIDR}
  Maestro:               ${MASTER_HOSTNAME} (${MASTER_IB_IP})
  NFS remoto:            ${MASTER_HOSTNAME}:${NFS_EXPORT_PATH} -> ${NFS_MOUNT_POINT}
  Usuario/grupo cluster: ${CLUSTER_USER}:${CLUSTER_GROUP}
  apt upgrade:           ${DO_APT_UPGRADE}
  Mitigaciones Ryzen:    ${DO_RYZEN_CSTATE_FIX}
  Copiar llave a master: ${DO_SSH_COPY_TO_MASTER}
  Editar exports remoto: ${DO_REMOTE_EXPORTS}
  Montar NFS:            ${DO_MOUNT_NFS}
  Buscar libs descargadas: ${DO_CHECK_DOWNLOADS} ${DOWNLOADS_DIR:+(${DOWNLOADS_DIR})}
EOF
    echo
    confirm "¿Continuar con esta configuracion?" "s" || { info "Cancelado por el usuario."; exit 0; }

    {
        echo "NODE_NAME=${NODE_NAME}"
        echo "NODE_IB_IP=${NODE_IB_IP}"
        echo "MASTER_HOSTNAME=${MASTER_HOSTNAME}"
        echo "MASTER_IB_IP=${MASTER_IB_IP}"
        echo "NFS_EXPORT_PATH=${NFS_EXPORT_PATH}"
        echo "NFS_MOUNT_POINT=${NFS_MOUNT_POINT}"
        echo "CLUSTER_USER=${CLUSTER_USER}"
        echo "CLUSTER_GROUP=${CLUSTER_GROUP}"
        echo "CONFIGURED_AT=$(date -Is)"
    } > "${STATE_FILE}"
}

# ============================================================================
# 3. Actualizacion del sistema
# ============================================================================

stage_system_update() {
    step "Actualizando indices de paquetes"
    apt-get update -y 2>&1 | tee -a "${LOG_FILE}"
    if [[ "${DO_APT_UPGRADE}" == true ]]; then
        info "Actualizando paquetes instalados (puede tardar varios minutos)..."
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y 2>&1 | tee -a "${LOG_FILE}"
    fi
    pkg_install curl wget ca-certificates gnupg lsb-release software-properties-common net-tools
}

# ============================================================================
# 4. Usuario/grupo + autologin
# ============================================================================

stage_user_and_autologin() {
    step "Configurando usuario/grupo '${CLUSTER_USER}' y autologin"

    if ! getent group "${CLUSTER_GROUP}" >/dev/null; then
        groupadd "${CLUSTER_GROUP}"
        ok "Grupo '${CLUSTER_GROUP}' creado."
    else
        info "El grupo '${CLUSTER_GROUP}' ya existe."
    fi

    if ! id "${CLUSTER_USER}" >/dev/null 2>&1; then
        useradd -m -s /bin/bash -g "${CLUSTER_GROUP}" -G sudo "${CLUSTER_USER}"
        ok "Usuario '${CLUSTER_USER}' creado (miembro de 'sudo')."
        warn "El usuario '${CLUSTER_USER}' fue creado sin contrasena. Define una con: passwd ${CLUSTER_USER}"
    else
        info "El usuario '${CLUSTER_USER}' ya existe."
        usermod -g "${CLUSTER_GROUP}" "${CLUSTER_USER}" 2>/dev/null || true
    fi

    # LightDM necesita que el usuario pertenezca al grupo usado por la
    # politica de autologin (nopasswdlogin) en sistemas Ubuntu/Mint.
    groupadd -f nopasswdlogin
    usermod -aG nopasswdlogin "${CLUSTER_USER}"

    if command -v lightdm >/dev/null 2>&1 || dpkg -l | grep -qi lightdm; then
        mkdir -p /etc/lightdm/lightdm.conf.d
        cat > /etc/lightdm/lightdm.conf.d/50-hpc-autologin.conf <<EOF
[Seat:*]
autologin-user=${CLUSTER_USER}
autologin-user-timeout=0
autologin-session=cinnamon
EOF
        ok "Autologin configurado en LightDM para '${CLUSTER_USER}'."
    else
        warn "No se detecto LightDM. Si este nodo usa otro gestor de sesiones (gdm3, sddm), configura el autologin manualmente."
    fi

    # Que la pantalla de bloqueo no se dispare al volver de la sesion:
    usermod -aG video,audio,plugdev "${CLUSTER_USER}" 2>/dev/null || true
}

# ============================================================================
# 5. Estabilidad de Cinnamon (sin bloqueo/suspension/salvapantallas)
# ============================================================================

stage_cinnamon_stability() {
    step "Ajustando Cinnamon para maxima estabilidad (sin suspension ni bloqueo)"

    # Importante: aqui SOLO se desactivan suspension/bloqueo/salvapantallas.
    # La interfaz grafica Cinnamon se deja siempre activa (nunca se cambia a
    # modo texto/headless) porque se necesita para monitorear el nodo
    # localmente mientras trabaja el cluster.
    systemctl set-default graphical.target 2>&1 | tee -a "${LOG_FILE}" || true
    if command -v lightdm >/dev/null 2>&1 || dpkg -l | grep -qi lightdm; then
        systemctl enable lightdm 2>&1 | tee -a "${LOG_FILE}" || true
    fi
    ok "Interfaz grafica Cinnamon garantizada activa (graphical.target + lightdm habilitados) para monitoreo local del nodo."

    if ! command -v dconf >/dev/null 2>&1; then
        warn "'dconf' no esta instalado; instalando..."
        pkg_install dconf-cli dconf-gsettings-backend
    fi

    mkdir -p /etc/dconf/profile
    cat > /etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF

    mkdir -p /etc/dconf/db/local.d
    cat > /etc/dconf/db/local.d/00-hpc-node-stability <<'EOF'
# Ajustes de estabilidad para nodos de computo: nunca suspender, nunca
# bloquear pantalla, nunca apagar el disco/monitor por inactividad.

[org/cinnamon/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0
sleep-display-ac=0
sleep-display-battery=0
idle-dim=false
button-power='shutdown'
button-suspend='nothing'
button-hibernate='nothing'
button-lid-ac='nothing'
button-lid-battery='nothing'
critical-battery-action='nothing'

[org/cinnamon/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false
ubuntu-lock-on-suspend=false

[org/cinnamon/desktop/session]
idle-delay=uint32 0

[org/cinnamon/desktop/notifications]
show-banners=true

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
EOF

    # Bloquear estas claves para que ningun usuario las cambie sin querer.
    mkdir -p /etc/dconf/db/local.d/locks
    cat > /etc/dconf/db/local.d/locks/hpc-node-stability <<'EOF'
/org/cinnamon/settings-daemon/plugins/power/sleep-inactive-ac-type
/org/cinnamon/settings-daemon/plugins/power/sleep-inactive-battery-type
/org/cinnamon/desktop/screensaver/lock-enabled
/org/cinnamon/desktop/screensaver/idle-activation-enabled
/org/cinnamon/desktop/session/idle-delay
EOF

    dconf update
    ok "Perfil dconf de estabilidad aplicado (efectivo en el proximo inicio de sesion)."

    # xscreensaver / DPMS por si acaso el entorno grafico X11 los usa.
    if [[ -d /etc/X11/xorg.conf.d ]]; then
        cat > /etc/X11/xorg.conf.d/10-hpc-no-dpms.conf <<'EOF'
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection
EOF
        ok "DPMS desactivado a nivel de Xorg."
    fi

    # Evitar reinicios/actualizaciones desatendidas que interrumpan trabajos largos.
    if dpkg -l | grep -q unattended-upgrades; then
        systemctl disable --now unattended-upgrades.service 2>/dev/null || true
        warn "Se desactivo 'unattended-upgrades' para evitar reinicios inesperados. Actualiza el sistema manualmente cuando convenga."
    fi
}

# ============================================================================
# 6. Desactivar suspension/hibernacion a nivel de systemd/logind
# ============================================================================

stage_disable_sleep() {
    step "Desactivando suspension/hibernacion a nivel del sistema"

    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>&1 | tee -a "${LOG_FILE}" || true
    ok "Objetivos systemd de suspension/hibernacion enmascarados."

    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/99-hpc-no-sleep.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF
    systemctl restart systemd-logind 2>&1 | tee -a "${LOG_FILE}" || warn "No se pudo reiniciar systemd-logind (puede requerir reinicio manual)."
    ok "logind configurado para ignorar tapa/inactividad/teclas de suspension."

    # Desactivar el autosuspend de USB, causa comun de "cuelgues" en nodos
    # sin monitor donde el teclado/mouse USB entra en ahorro de energia.
    cat > /etc/udev/rules.d/50-hpc-no-usb-autosuspend.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
EOF
    udevadm control --reload-rules 2>/dev/null || true
    ok "Autosuspend de USB desactivado."
}

# ============================================================================
# 7. Estados C / gobernador de CPU (estabilidad AMD Ryzen)
# ============================================================================

stage_cpu_stability() {
    step "Configurando gobernador de CPU y estados C para estabilidad"

    pkg_install linux-tools-common "linux-tools-$(uname -r)" cpufrequtils

    cat > /usr/local/sbin/hpc-set-cpu-performance.sh <<'EOF'
#!/usr/bin/env bash
# Fija el gobernador de frecuencia de todos los nucleos en "performance"
# para evitar transiciones de estado C/P problematicas en reposo.
for gov in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    [[ -w "${gov}" ]] && echo performance > "${gov}" 2>/dev/null
done
EOF
    chmod +x /usr/local/sbin/hpc-set-cpu-performance.sh

    cat > /etc/systemd/system/hpc-cpu-performance.service <<'EOF'
[Unit]
Description=Fijar gobernador de CPU en modo performance (estabilidad del nodo HPC)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hpc-set-cpu-performance.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now hpc-cpu-performance.service 2>&1 | tee -a "${LOG_FILE}"
    ok "Gobernador de CPU fijado en 'performance' (persistente via systemd)."

    if [[ "${DO_RYZEN_CSTATE_FIX}" == true ]]; then
        if [[ -f /etc/default/grub ]]; then
            backup_file /etc/default/grub
            local extra_params="processor.max_cstate=1 idle=nomwait"
            if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
                if ! grep -q "processor.max_cstate=1" /etc/default/grub; then
                    sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"(.*)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${extra_params}\"|" /etc/default/grub
                fi
            else
                echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${extra_params}\"" >> /etc/default/grub
            fi
            update-grub 2>&1 | tee -a "${LOG_FILE}" || warn "update-grub fallo; revisa /etc/default/grub manualmente."
            ok "Parametros de kernel 'processor.max_cstate=1 idle=nomwait' agregados (requieren reinicio)."
            warn "Estos parametros son un workaround conocido para congelamientos por estados C profundos en plataformas AMD Ryzen. Si el problema persiste, revisa tambien en la BIOS: 'Global C-State Control' / 'Core C6 State' -> Disabled, y actualiza el firmware/BIOS de la board."
        else
            warn "No se encontro /etc/default/grub (¿este sistema no usa GRUB?). Omite el ajuste de parametros de kernel."
        fi
    fi

    # Reducir el uso de swap para minimizar pausas por intercambio de memoria
    # en nodos que corren trabajos MPI intensivos en RAM.
    cat > /etc/sysctl.d/99-hpc-stability.conf <<'EOF'
vm.swappiness=10
vm.dirty_ratio=10
vm.dirty_background_ratio=5
kernel.panic=10
kernel.panic_on_oops=1
EOF
    sysctl --system 2>&1 | tee -a "${LOG_FILE}" >/dev/null
    ok "Ajustes de sysctl aplicados (swappiness bajo, reinicio automatico tras panico de kernel)."
}

# ============================================================================
# 8. Limites de memoria (memlock, nofile) para RDMA
# ============================================================================

stage_memory_limits() {
    step "Configurando limites de memoria (memlock/nofile) para RDMA"

    mkdir -p /etc/security/limits.d
    cat > /etc/security/limits.d/99-hpc-cluster.conf <<EOF
# RDMA/InfiniBand requiere poder anclar (pin) memoria sin limite para
# registrar regiones de memoria con los verbs de Mellanox.
@${CLUSTER_GROUP}   soft    memlock   unlimited
@${CLUSTER_GROUP}   hard    memlock   unlimited
${CLUSTER_USER}     soft    memlock   unlimited
${CLUSTER_USER}     hard    memlock   unlimited
@${CLUSTER_GROUP}   soft    nofile    1048576
@${CLUSTER_GROUP}   hard    nofile    1048576
${CLUSTER_USER}     soft    nofile    1048576
${CLUSTER_USER}     hard    nofile    1048576
@${CLUSTER_GROUP}   soft    stack     unlimited
@${CLUSTER_GROUP}   hard    stack     unlimited
root                soft    memlock   unlimited
root                hard    memlock   unlimited
EOF
    ok "Limites definidos en /etc/security/limits.d/99-hpc-cluster.conf"

    # Asegurar que pam_limits este habilitado (normalmente ya lo esta en Ubuntu/Mint).
    for pamfile in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        if [[ -f "${pamfile}" ]] && ! grep -q "pam_limits.so" "${pamfile}"; then
            echo "session required pam_limits.so" >> "${pamfile}"
            ok "pam_limits habilitado en ${pamfile}"
        fi
    done

    # Los procesos lanzados por systemd (incluido sshd en algunos setups)
    # no siempre heredan limits.conf; se fija tambien a nivel de systemd.
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-hpc-memlock.conf <<'EOF'
[Manager]
DefaultLimitMEMLOCK=infinity
EOF

    mkdir -p /etc/systemd/system/ssh.service.d
    cat > /etc/systemd/system/ssh.service.d/99-hpc-memlock.conf <<'EOF'
[Service]
LimitMEMLOCK=infinity
EOF
    systemctl daemon-reload
    systemctl try-restart ssh 2>/dev/null || systemctl try-restart sshd 2>/dev/null || true
    ok "DefaultLimitMEMLOCK=infinity aplicado tambien a systemd y al servicio SSH."
}

# ============================================================================
# 9. Paquetes RDMA/InfiniBand + modulos mlx5
# ============================================================================

stage_infiniband_packages() {
    step "Instalando pila RDMA/InfiniBand (drivers mlx5, verbs, herramientas)"

    pkg_install \
        rdma-core \
        ibverbs-utils \
        ibverbs-providers \
        libibverbs1 \
        libibverbs-dev \
        librdmacm1 \
        librdmacm-dev \
        rdmacm-utils \
        infiniband-diags \
        ibutils \
        perftest \
        opensm \
        srptools \
        libibumad3

    cat > /etc/modules-load.d/hpc-infiniband.conf <<'EOF'
# Modulos necesarios para tarjetas Mellanox ConnectX (driver mlx5) e IPoIB.
mlx5_core
mlx5_ib
ib_core
ib_uverbs
ib_umad
ib_ipoib
rdma_ucm
rdma_cm
EOF

    while read -r mod; do
        [[ -z "${mod}" || "${mod}" == \#* ]] && continue
        modprobe "${mod}" 2>>"${LOG_FILE}" && info "Modulo cargado: ${mod}" || warn "No se pudo cargar el modulo ${mod} (¿falta la tarjeta fisica o el firmware?)."
    done < /etc/modules-load.d/hpc-infiniband.conf

    systemctl enable --now rdma-load-modules@rdma.service 2>&1 | tee -a "${LOG_FILE}" || true
    systemctl enable --now rdma-ndd 2>&1 | tee -a "${LOG_FILE}" || true

    # Si no se detecta fisicamente la tarjeta, el script se detiene aqui y
    # espera que el usuario decida (reintentar tras revisarla, continuar sin
    # InfiniBand, o abortar) en vez de asumir silenciosamente que no esta.
    wait_for_ib_card

    if [[ "${IB_CARD_PRESENT}" == true ]]; then
        if ibv_devices >/dev/null 2>&1; then
            info "Dispositivos verbs disponibles:"
            ibv_devices | tee -a "${LOG_FILE}"
        else
            warn "El comando 'ibv_devices' no listo ningun dispositivo todavia. Puede requerir un reinicio para que el driver mlx5 tome el control completo de la tarjeta."
        fi
    fi
}

# ============================================================================
# 9b. Bibliotecas HPC desde paquetes descargados (UCX/libfabric/LibXC/OpenMPI)
# ============================================================================

stage_custom_hpc_libraries() {
    step "Bibliotecas HPC desde paquetes descargados (UCX/libfabric/LibXC/OpenMPI)"

    if [[ "${DO_CHECK_DOWNLOADS}" != true ]]; then
        info "Se omitio la busqueda de paquetes descargados; el toolchain MPI se instalara desde el repositorio mas adelante."
        return 0
    fi

    local downloads_dir="${DOWNLOADS_DIR}"
    if [[ ! -d "${downloads_dir}" ]]; then
        for alt in "/home/${CLUSTER_USER}/Descargas" "/home/${CLUSTER_USER}/Downloads"; do
            [[ -d "${alt}" ]] && { downloads_dir="${alt}"; break; }
        done
    fi
    if [[ ! -d "${downloads_dir}" ]]; then
        warn "No se encontro la carpeta de descargas '${DOWNLOADS_DIR}'. Se omite esta etapa; el toolchain MPI se instalara desde el repositorio."
        return 0
    fi
    info "Buscando paquetes en: ${downloads_dir}"

    pkg_install build-essential gfortran automake autoconf libtool pkg-config cmake

    local ucx_tar
    ucx_tar="$(find_downloaded_archive "${downloads_dir}" "ucx")"
    if [[ -n "${ucx_tar}" ]] && confirm "Se encontro '$(basename "${ucx_tar}")'. ¿Compilarlo e instalarlo en vez del UCX del repositorio?" "s"; then
        if build_from_source "UCX" "${ucx_tar}" "${HPC_STACK_PREFIX}/ucx" --with-verbs; then
            UCX_PREFIX="${HPC_STACK_PREFIX}/ucx"
            ok "UCX compilado e instalado en ${UCX_PREFIX}."
        else
            warn "Fallo la compilacion de UCX; se usara el paquete del repositorio para OpenMPI."
        fi
    fi

    local ofi_tar
    ofi_tar="$(find_downloaded_archive "${downloads_dir}" "libfabric")"
    if [[ -n "${ofi_tar}" ]] && confirm "Se encontro '$(basename "${ofi_tar}")'. ¿Compilarlo e instalarlo (proveedor OFI/libfabric alternativo para OpenMPI)?" "s"; then
        if build_from_source "libfabric" "${ofi_tar}" "${HPC_STACK_PREFIX}/libfabric" --enable-verbs; then
            LIBFABRIC_PREFIX="${HPC_STACK_PREFIX}/libfabric"
            ok "libfabric compilado e instalado en ${LIBFABRIC_PREFIX}."
        else
            warn "Fallo la compilacion de libfabric; se omite (OpenMPI seguira usando UCX/verbs)."
        fi
    fi

    local libxc_tar
    libxc_tar="$(find_downloaded_archive "${downloads_dir}" "libxc")"
    if [[ -n "${libxc_tar}" ]] && confirm "Se encontro '$(basename "${libxc_tar}")'. ¿Compilarlo e instalarlo (lo usara luego Quantum ESPRESSO)?" "s"; then
        if build_from_source "LibXC" "${libxc_tar}" "${HPC_STACK_PREFIX}/libxc"; then
            LIBXC_PREFIX="${HPC_STACK_PREFIX}/libxc"
            ok "LibXC compilado e instalado en ${LIBXC_PREFIX}."
        else
            warn "Fallo la compilacion de LibXC; se puede instalar mas adelante junto con Quantum ESPRESSO."
        fi
    fi

    local ompi_tar
    ompi_tar="$(find_downloaded_archive "${downloads_dir}" "openmpi")"
    if [[ -n "${ompi_tar}" ]] && confirm "Se encontro '$(basename "${ompi_tar}")'. ¿Compilarlo e instalarlo usando el UCX/libfabric recien compilados (recomendado para InfiniBand)?" "s"; then
        local ompi_args=(--with-verbs)
        [[ -n "${UCX_PREFIX}" ]] && ompi_args+=(--with-ucx="${UCX_PREFIX}")
        [[ -n "${LIBFABRIC_PREFIX}" ]] && ompi_args+=(--with-ofi="${LIBFABRIC_PREFIX}")
        if build_from_source "OpenMPI" "${ompi_tar}" "${HPC_STACK_PREFIX}/openmpi" "${ompi_args[@]}"; then
            OPENMPI_BUILT_FROM_SOURCE=true
            ok "OpenMPI compilado e instalado en ${HPC_STACK_PREFIX}/openmpi."
        else
            warn "Fallo la compilacion de OpenMPI; se usara el paquete openmpi-bin del repositorio."
        fi
    elif [[ -n "${UCX_PREFIX}" || -n "${LIBFABRIC_PREFIX}" ]]; then
        warn "Se compilaron UCX/libfabric manualmente pero OpenMPI se instalara desde el repositorio y no aprovechara esas bibliotecas. Si quieres que las use, descarga tambien el tarball de OpenMPI y vuelve a ejecutar el script."
    fi

    if [[ "${OPENMPI_BUILT_FROM_SOURCE}" == true ]]; then
        cat > /etc/profile.d/hpc-stack.sh <<EOF
# Entorno para la pila HPC compilada manualmente (mas reciente/estable que
# los paquetes del repositorio), instalada en ${HPC_STACK_PREFIX}.
export PATH="${HPC_STACK_PREFIX}/openmpi/bin:\${PATH}"
export LD_LIBRARY_PATH="${HPC_STACK_PREFIX}/openmpi/lib:${UCX_PREFIX:+${UCX_PREFIX}/lib:}${LIBFABRIC_PREFIX:+${LIBFABRIC_PREFIX}/lib:}\${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="${HPC_STACK_PREFIX}/openmpi/lib/pkgconfig:\${PKG_CONFIG_PATH:-}"
EOF
        chmod 644 /etc/profile.d/hpc-stack.sh
        ldconfig
        ok "Variables de entorno para la pila HPC compilada publicadas en /etc/profile.d/hpc-stack.sh"
    fi

    {
        echo "UCX_PREFIX=${UCX_PREFIX}"
        echo "LIBFABRIC_PREFIX=${LIBFABRIC_PREFIX}"
        echo "LIBXC_PREFIX=${LIBXC_PREFIX}"
        echo "OPENMPI_BUILT_FROM_SOURCE=${OPENMPI_BUILT_FROM_SOURCE}"
    } >> "${STATE_FILE}"
}

# ============================================================================
# 10. Interfaz IPoIB (ib0) con IP estatica
# ============================================================================

stage_ipoib_interface() {
    step "Configurando interfaz IPoIB con IP estatica ${NODE_IB_IP}/${IB_NETMASK_CIDR}"

    if [[ "${IB_CARD_PRESENT}" != true ]]; then
        warn "Se omite la configuracion de IPoIB porque no se detecto la tarjeta InfiniBand. Vuelve a ejecutar este script cuando la tarjeta este instalada."
        return 0
    fi

    local ib_iface=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
        ib_iface="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^ib[0-9]+$' | head -n1)"
        [[ -n "${ib_iface}" ]] && break
        sleep 1
    done

    if [[ -z "${ib_iface}" ]]; then
        err "No se encontro ninguna interfaz ib* (ib0). El modulo mlx5_ib puede no haber podido inicializar la tarjeta. Revisa 'dmesg | grep -i mlx5' y 'lspci | grep -i mellanox'."
        return 1
    fi
    ok "Interfaz InfiniBand detectada: ${ib_iface}"

    if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
        nmcli connection delete "hpc-${ib_iface}" >/dev/null 2>&1 || true
        nmcli connection add type infiniband ifname "${ib_iface}" con-name "hpc-${ib_iface}" \
            ip4 "${NODE_IB_IP}/${IB_NETMASK_CIDR}" \
            infiniband.transport-mode connected \
            connection.autoconnect yes \
            802-3-ethernet.mtu 65520 2>&1 | tee -a "${LOG_FILE}" \
            || nmcli connection add type infiniband ifname "${ib_iface}" con-name "hpc-${ib_iface}" \
                ip4 "${NODE_IB_IP}/${IB_NETMASK_CIDR}" connection.autoconnect yes 2>&1 | tee -a "${LOG_FILE}"
        nmcli connection up "hpc-${ib_iface}" 2>&1 | tee -a "${LOG_FILE}" || warn "No se pudo activar la conexion ${ib_iface} automaticamente; revisa 'nmcli connection show'."
        ok "Interfaz ${ib_iface} configurada via NetworkManager con IP ${NODE_IB_IP}."
    else
        warn "NetworkManager no esta activo; configurando ${ib_iface} directamente con 'ip' (no persiste tras reiniciar)."
        ip addr add "${NODE_IB_IP}/${IB_NETMASK_CIDR}" dev "${ib_iface}" 2>/dev/null || true
        ip link set "${ib_iface}" up
    fi

    # Forzar modo "connected" para maximo MTU/rendimiento, de forma persistente.
    cat > /etc/udev/rules.d/60-hpc-ipoib-mode.rules <<EOF
ACTION=="add|change", SUBSYSTEM=="net", KERNEL=="${ib_iface}", RUN+="/bin/sh -c 'echo connected > /sys/class/net/%k/mode; echo 65520 > /sys/class/net/%k/mtu'"
EOF
    echo connected > "/sys/class/net/${ib_iface}/mode" 2>/dev/null || true
    ip link set "${ib_iface}" mtu 65520 2>/dev/null || true

    IB_IFACE="${ib_iface}"
    echo "IB_IFACE=${ib_iface}" >> "${STATE_FILE}"
}

# ============================================================================
# 11. /etc/hosts del cluster
# ============================================================================

stage_hosts_file() {
    step "Actualizando /etc/hosts"

    backup_file /etc/hosts
    append_once /etc/hosts "${MASTER_IB_IP}	${MASTER_HOSTNAME}"
    append_once /etc/hosts "${NODE_IB_IP}	${NODE_NAME}"
    ok "/etc/hosts actualizado con ${MASTER_HOSTNAME} (${MASTER_IB_IP}) y ${NODE_NAME} (${NODE_IB_IP})."

    if [[ "$(hostname)" != "${NODE_NAME}" ]]; then
        if confirm "El hostname actual es '$(hostname)'. ¿Cambiarlo a '${NODE_NAME}'?" "s"; then
            hostnamectl set-hostname "${NODE_NAME}"
            sed -i "s/127.0.1.1.*/127.0.1.1\t${NODE_NAME}/" /etc/hosts 2>/dev/null || append_once /etc/hosts "127.0.1.1	${NODE_NAME}"
            ok "Hostname cambiado a ${NODE_NAME}."
        fi
    fi
}

# ============================================================================
# 12. Llaves SSH hacia/desde el nodo master
# ============================================================================

stage_ssh_keys() {
    step "Configurando llaves SSH para el usuario ${CLUSTER_USER}"

    pkg_install openssh-client openssh-server
    systemctl enable --now ssh 2>&1 | tee -a "${LOG_FILE}" || true

    local user_home
    user_home="$(getent passwd "${CLUSTER_USER}" | cut -d: -f6)"
    local ssh_dir="${user_home}/.ssh"

    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"

    if [[ ! -f "${ssh_dir}/id_ed25519" ]]; then
        sudo -u "${CLUSTER_USER}" ssh-keygen -t ed25519 -N "" -f "${ssh_dir}/id_ed25519" -C "${CLUSTER_USER}@${NODE_NAME}"
        ok "Par de llaves SSH generado para ${CLUSTER_USER}."
    else
        info "Ya existe un par de llaves SSH para ${CLUSTER_USER}, se reutiliza."
    fi
    chown -R "${CLUSTER_USER}:${CLUSTER_GROUP}" "${ssh_dir}"

    touch "${ssh_dir}/known_hosts"
    timeout 10 ssh-keyscan -H "${MASTER_IB_IP}" >> "${ssh_dir}/known_hosts" 2>/dev/null
    timeout 10 ssh-keyscan -H "${MASTER_HOSTNAME}" >> "${ssh_dir}/known_hosts" 2>/dev/null
    sort -u -o "${ssh_dir}/known_hosts" "${ssh_dir}/known_hosts"
    chown "${CLUSTER_USER}:${CLUSTER_GROUP}" "${ssh_dir}/known_hosts"
    ok "known_hosts actualizado con la llave del maestro."

    echo
    echo -e "${COLOR_BOLD}Llave publica de este nodo (agregala a ~${CLUSTER_USER}/.ssh/authorized_keys en el maestro si no se copia automaticamente):${COLOR_RESET}"
    cat "${ssh_dir}/id_ed25519.pub"
    echo

    if [[ "${DO_SSH_COPY_TO_MASTER}" == true ]]; then
        info "Copiando la llave publica al maestro (se te pedira la contrasena de ${CLUSTER_USER}@${MASTER_HOSTNAME})..."
        if sudo -u "${CLUSTER_USER}" ssh-copy-id -i "${ssh_dir}/id_ed25519.pub" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${CLUSTER_USER}@${MASTER_IB_IP}"; then
            ok "Llave copiada al maestro correctamente."
            SSH_TRUST_OK=true
        else
            warn "No se pudo copiar la llave automaticamente. Copiala manualmente con: ssh-copy-id ${CLUSTER_USER}@${MASTER_IB_IP}"
            SSH_TRUST_OK=false
        fi
    else
        SSH_TRUST_OK=false
    fi
}

# ============================================================================
# 13. Cliente NFS + montaje de /cluster
# ============================================================================

stage_nfs_client() {
    step "Configurando cliente NFS y montando ${NFS_MOUNT_POINT}"

    if [[ "${DO_MOUNT_NFS}" != true ]]; then
        info "Se omitio el montaje de NFS a peticion del usuario."
        return 0
    fi

    pkg_install nfs-common

    mkdir -p "${NFS_MOUNT_POINT}"

    local fstab_line="${MASTER_HOSTNAME}:${NFS_EXPORT_PATH}  ${NFS_MOUNT_POINT}  nfs  defaults,_netdev,noatime,rsize=1048576,wsize=1048576  0  0"
    backup_file /etc/fstab
    if ! grep -qF "${MASTER_HOSTNAME}:${NFS_EXPORT_PATH}" /etc/fstab; then
        echo "${fstab_line}" >> /etc/fstab
        ok "Entrada agregada a /etc/fstab."
    else
        info "Ya existe una entrada de fstab para ${MASTER_HOSTNAME}:${NFS_EXPORT_PATH}."
    fi

    systemctl daemon-reload
    if mount "${NFS_MOUNT_POINT}" 2>&1 | tee -a "${LOG_FILE}"; then
        ok "Montaje de ${NFS_MOUNT_POINT} exitoso."
    else
        warn "No se pudo montar ${NFS_MOUNT_POINT} todavia. Esto es normal si el maestro aun no exporta esa ruta para este nodo (ver siguiente paso) o si la red IB no esta activa. Se reintentara en cada arranque via fstab."
    fi
}

# ============================================================================
# 14. (Opcional) registrar el nodo en /etc/exports del master via SSH
# ============================================================================

stage_remote_exports() {
    step "Registrando este nodo en /etc/exports del maestro (opcional)"

    if [[ "${DO_REMOTE_EXPORTS}" != true || "${SSH_TRUST_OK}" != true ]]; then
        if [[ "${DO_REMOTE_EXPORTS}" == true ]]; then
            warn "No se pudo confirmar que la llave SSH quedo instalada en el maestro; se omite el ajuste automatico de /etc/exports."
        else
            info "Se omitio este paso a peticion del usuario."
        fi
        cat <<EOF
Para dar acceso manualmente, en el nodo MAESTRO agrega una linea como esta
a /etc/exports y luego ejecuta 'sudo exportfs -ra':

  ${NFS_EXPORT_PATH}  ${NODE_IB_IP}(rw,sync,no_subtree_check,no_root_squash)

EOF
        return 0
    fi

    local export_line="${NFS_EXPORT_PATH} ${NODE_IB_IP}(rw,sync,no_subtree_check,no_root_squash)"
    local remote_cmd="grep -qF '${NODE_IB_IP}' /etc/exports 2>/dev/null || echo '${export_line}' | sudo tee -a /etc/exports >/dev/null; sudo exportfs -ra"

    if sudo -u "${CLUSTER_USER}" ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${CLUSTER_USER}@${MASTER_IB_IP}" "${remote_cmd}" 2>&1 | tee -a "${LOG_FILE}"; then
        ok "El maestro ahora exporta ${NFS_EXPORT_PATH} para ${NODE_IB_IP}."
    else
        warn "No se pudo modificar /etc/exports en el maestro automaticamente (¿el usuario ${CLUSTER_USER} tiene sudo alli y la llave SSH quedo instalada?). Hazlo manualmente con la linea mostrada arriba."
    fi
}

# ============================================================================
# 15. Toolchain MPI/OpenMP
# ============================================================================

stage_mpi_toolchain() {
    step "Instalando toolchain de compilacion y MPI (OpenMPI + UCX + OpenMP)"

    # gcc/g++/gfortran ya traen soporte de OpenMP (-fopenmp); no requieren
    # un paquete aparte.
    pkg_install build-essential gfortran cmake pkg-config environment-modules

    if [[ "${OPENMPI_BUILT_FROM_SOURCE}" == true ]]; then
        info "OpenMPI ya fue compilado desde el tarball descargado (etapa anterior) en ${HPC_STACK_PREFIX}/openmpi; se omiten los paquetes openmpi-bin/libucx del repositorio para evitar que convivan dos instalaciones distintas."
        hash -r
    else
        # OpenMPI es el que habilita la comunicacion entre nodos (y usara los
        # verbs de InfiniBand automaticamente si UCX/ibverbs estan presentes).
        pkg_install openmpi-bin openmpi-common libopenmpi-dev libucx0 libucx-dev ucx-utils

        mkdir -p /etc/openmpi
        cat > /etc/openmpi/openmpi-mca-params.conf <<'EOF'
# Preferir UCX (que a su vez usa los verbs de Mellanox/mlx5) para el
# transporte entre nodos; usar memoria compartida dentro de un mismo nodo.
pml = ucx
btl = self,vader
osc = ucx
EOF
        ok "OpenMPI (repositorio) configurado para preferir UCX/InfiniBand entre nodos."

        cat > /etc/profile.d/hpc-mpi.sh <<'EOF'
# Entorno MPI/InfiniBand para todos los usuarios del cluster.
export OMPI_MCA_pml=ucx
export OMPI_MCA_btl=self,vader
EOF
        chmod 644 /etc/profile.d/hpc-mpi.sh
        ok "Variables de entorno MPI publicadas en /etc/profile.d/hpc-mpi.sh"
    fi

    if [[ -n "${LIBXC_PREFIX}" ]]; then
        info "LibXC ya esta compilado en ${LIBXC_PREFIX}, listo para cuando instales Quantum ESPRESSO."
    elif apt-cache show libxc-dev >/dev/null 2>&1; then
        pkg_install libxc-dev
        info "libxc-dev instalado desde el repositorio como base minima para Quantum ESPRESSO."
    fi

    if command -v mpirun >/dev/null 2>&1; then
        info "$(mpirun --version | head -n1)"
    fi
}

# ============================================================================
# 16. Resumen final
# ============================================================================

final_summary() {
    echo
    echo -e "${COLOR_BOLD}${COLOR_GREEN}=== Configuracion del nodo '${NODE_NAME}' finalizada ===${COLOR_RESET}"
    echo
    echo "Resumen de red InfiniBand:"
    echo "  Tarjeta detectada: ${IB_CARD_PRESENT}"
    echo "  Interfaz:        ${IB_IFACE:-no detectada}"
    echo "  IP de este nodo: ${NODE_IB_IP}"
    echo "  Maestro:         ${MASTER_HOSTNAME} (${MASTER_IB_IP})"
    echo "  Recurso NFS:     ${MASTER_HOSTNAME}:${NFS_EXPORT_PATH} -> ${NFS_MOUNT_POINT}"
    echo
    echo "Bibliotecas HPC compiladas manualmente:"
    echo "  UCX:       ${UCX_PREFIX:-no (repositorio)}"
    echo "  libfabric: ${LIBFABRIC_PREFIX:-no instalado}"
    echo "  LibXC:     ${LIBXC_PREFIX:-no instalado}"
    echo "  OpenMPI:   $([[ "${OPENMPI_BUILT_FROM_SOURCE}" == true ]] && echo "${HPC_STACK_PREFIX}/openmpi (compilado)" || echo "repositorio")"
    echo

    if [[ ${#FAILED_STEPS[@]} -gt 0 ]]; then
        warn "Las siguientes etapas reportaron errores y deben revisarse en ${LOG_FILE}:"
        for s in "${FAILED_STEPS[@]}"; do
            echo "   - ${s}"
        done
        echo
    else
        ok "Todas las etapas se ejecutaron sin errores fatales."
    fi

    cat <<EOF
Pasos manuales pendientes (fuera del alcance de este script):
  1. Define la contrasena del usuario '${CLUSTER_USER}' si aun no la tiene: passwd ${CLUSTER_USER}
  2. Verifica la conectividad InfiniBand una vez reiniciado:
       ibstat
       ibping -S            (en el maestro)
       ibping -c 3 <lid_del_maestro>   (en este nodo)
       ping ${MASTER_IB_IP}
  3. Prueba MPI entre nodos, por ejemplo:
       mpirun --host ${NODE_NAME},${MASTER_HOSTNAME} -np 2 hostname
  4. Si activaste las mitigaciones de estados C, REINICIA el nodo para que
     los parametros de kernel tomen efecto.
  5. Instala luego Intel MKL y Quantum ESPRESSO (con su interfaz grafica)
     sobre esta base; el toolchain de compilacion y MPI ya esta listo.
  6. Revisa en la BIOS del nodo: 'Global C-State Control' / 'Core C6 State'
     en Disabled, y el plan de energia en modo alto rendimiento, para
     complementar los ajustes de software aplicados aqui.

Log completo: ${LOG_FILE}
Parametros usados guardados en: ${STATE_FILE}
EOF

    if confirm "¿Reiniciar el nodo ahora para aplicar todos los cambios (gobernador de CPU, C-states, IPoIB, autologin)?" "n"; then
        info "Reiniciando..."
        reboot
    else
        warn "Recuerda reiniciar el nodo manualmente antes de darlo por operativo."
    fi
}

# ============================================================================
# main
# ============================================================================

main() {
    preflight
    gather_input

    run_stage stage_system_update        "Actualizacion del sistema"
    run_stage stage_user_and_autologin   "Usuario y autologin"
    run_stage stage_cinnamon_stability   "Estabilidad de Cinnamon"
    run_stage stage_disable_sleep        "Desactivar suspension/hibernacion"
    run_stage stage_cpu_stability        "Estabilidad de CPU (gobernador/C-states)"
    run_stage stage_memory_limits        "Limites de memoria para RDMA"
    run_stage stage_infiniband_packages  "Paquetes RDMA/InfiniBand"
    run_stage stage_custom_hpc_libraries "Bibliotecas HPC desde paquetes descargados"
    run_stage stage_ipoib_interface      "Interfaz IPoIB"
    run_stage stage_hosts_file           "/etc/hosts"
    run_stage stage_ssh_keys             "Llaves SSH"
    run_stage stage_nfs_client           "Cliente NFS"
    run_stage stage_remote_exports       "Exports remotos en el maestro"
    run_stage stage_mpi_toolchain        "Toolchain MPI/OpenMP"

    final_summary
}

main "$@"
