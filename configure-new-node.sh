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
#  10) Bibliotecas HPC desde paquetes descargados (UCX/libfabric/LibXC/OpenMPI),
#      todas en el MISMO prefijo (configurable) que los demas nodos
#  11) Interfaz IPoIB (ib0) con IP estatica
#  12) /etc/hosts del cluster
#  13) Llaves SSH hacia/desde el nodo master
#  14) Cliente NFS + montaje de /cluster (con arranque automatico via
#      rpcbind/remote-fs.target)
#  14b) Directorio compartido del cluster (en el propio NFS): fusiona
#      /etc/hosts y authorized_keys de todos los nodos, incluyendo el
#      auto-registro de este mismo nodo
#  15) (Opcional) registrar el nodo en /etc/exports del master via SSH
#  16) Toolchain MPI/OpenMP (OpenMPI + UCX + build-essential)
#  17) Variables de entorno en ~/.bashrc (interactivo Y no interactivo, para
#      que mpirun via SSH tambien las vea; incluye MKL y afinidad Threadripper)
#  18) Resumen final
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
# Valor por defecto; se pregunta en gather_input porque DEBE coincidir con
# la mascara que ya usan los demas nodos (una referencia real de este mismo
# cluster mostro 255.255.0.0 = /16, no /24 -- confirma cual es la correcta).
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
# Prefijo de instalacion para UCX/libfabric/LibXC/OpenMPI compilados desde
# fuente. DEBE ser el mismo en todos los nodos del cluster; /usr/local es la
# ruta por defecto que usan las bibliotecas cuando se compilan con
# "./configure" sin --prefix, que es como suelen quedar instaladas en los
# nodos existentes.
HPC_INSTALL_PREFIX="/usr/local"
UCX_BUILT_FROM_SOURCE=false
LIBFABRIC_BUILT_FROM_SOURCE=false
LIBXC_BUILT_FROM_SOURCE=false
OPENMPI_BUILT_FROM_SOURCE=false
DO_PCIE_ACS_OVERRIDE=false

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

inject_bashrc_block() {
    # inject_bashrc_block <archivo_bashrc> <contenido>
    #
    # Inserta <contenido> AL PRINCIPIO de <archivo_bashrc>, antes de
    # cualquier otra linea existente. Esto es a proposito: el .bashrc por
    # defecto de Debian/Ubuntu empieza con un guardian tipo
    #   case $- in *i*) ;; *) return;; esac
    # que corta la ejecucion para shells NO interactivas. Cuando OpenMPI
    # lanza procesos remotos via "ssh nodo comando", esa shell remota es no
    # interactiva y NUNCA llega a leer nada que este despues de ese
    # guardian. Poniendo nuestras variables ANTES de ese punto, tanto las
    # sesiones interactivas (terminal) como las no interactivas (mpirun via
    # ssh) las heredan por igual.
    #
    # Es idempotente: si ya existe un bloque marcado, lo reemplaza en el
    # mismo lugar en vez de duplicarlo.
    local bashrc_file="$1"
    local content="$2"
    local marker_start="# >>> hpc-cluster-new-nodes-script (bloque generado automaticamente; no borrar) >>>"
    local marker_end="# <<< hpc-cluster-new-nodes-script <<<"

    touch "${bashrc_file}"

    local rest_file
    rest_file="$(mktemp)"
    if grep -qF "${marker_start}" "${bashrc_file}"; then
        awk -v start="${marker_start}" -v end="${marker_end}" '
            $0==start {skip=1; next}
            $0==end   {skip=0; next}
            !skip {print}
        ' "${bashrc_file}" > "${rest_file}"
    else
        cp "${bashrc_file}" "${rest_file}"
    fi

    local new_file
    new_file="$(mktemp)"
    {
        echo "${marker_start}"
        echo "${content}"
        echo "${marker_end}"
        echo
        cat "${rest_file}"
    } > "${new_file}"

    mv "${new_file}" "${bashrc_file}"
    rm -f "${rest_file}"
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
    IB_NETMASK_CIDR="$(ask "Mascara de la red InfiniBand en formato CIDR (24 = 255.255.255.0, 16 = 255.255.0.0). DEBE coincidir con la de los demas nodos" "${IB_NETMASK_CIDR}")"

    echo
    echo -e "${COLOR_BOLD}--- Recursos remotos ---${COLOR_RESET}"
    NFS_EXPORT_PATH="$(ask "Ruta exportada por NFS en el maestro" "${SHARED_MOUNT_POINT}")"
    NFS_MOUNT_POINT="$(ask "Punto de montaje local para esa carpeta compartida" "${SHARED_MOUNT_POINT}")"

    DO_NFS_RDMA=false
    info "NFS sobre RDMA (en vez de TCP/IPoIB normal) da menor latencia, pero requiere que el maestro tenga el modulo 'svcrdma' cargado y 'echo rdma 20049 > /proc/fs/nfsd/portlist' ejecutado despues de levantar nfsd."
    confirm "¿Montar el recurso NFS usando RDMA (puerto 20049)?" "n" && DO_NFS_RDMA=true

    echo
    echo -e "${COLOR_BOLD}--- Cuenta de trabajo ---${COLOR_RESET}"
    CLUSTER_USER="$(ask "Usuario estandar del cluster" "${CLUSTER_USER}")"
    CLUSTER_GROUP="$(ask "Grupo estandar del cluster" "${CLUSTER_GROUP}")"

    echo
    echo -e "${COLOR_BOLD}--- Opciones ---${COLOR_RESET}"
    DO_APT_UPGRADE=false
    confirm "¿Actualizar todos los paquetes del sistema (apt upgrade) antes de continuar?" "s" && DO_APT_UPGRADE=true

    DO_RYZEN_CSTATE_FIX=false
    confirm "¿Aplicar mitigaciones de estabilidad para congelamientos tipicos de plataformas AMD Ryzen/Threadripper (1950X/2990WX): C-states/gobernador de CPU?" "s" && DO_RYZEN_CSTATE_FIX=true

    DO_PCIE_ACS_OVERRIDE=false
    info "En plataformas Threadripper (2990WX/1950X) el ACS de PCIe suele forzar todo el trafico peer-to-peer (tarjetas InfiniBand, GPUs) a pasar por el root complex del CPU, con mas latencia. El parametro de kernel 'pcie_acs_override=downstream,multifunction' es el workaround documentado por la comunidad para evitarlo. Tiene una contrapartida: relaja el aislamiento IOMMU entre dispositivos (relevante solo si usas paso de PCI a maquinas virtuales)."
    confirm "¿Aplicar 'pcie_acs_override=downstream,multifunction' para mejorar el trafico peer-to-peer en Threadripper?" "s" && DO_PCIE_ACS_OVERRIDE=true

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
        HPC_INSTALL_PREFIX="$(ask "Prefijo de instalacion para UCX/libfabric/LibXC/OpenMPI (debe ser EXACTAMENTE el mismo en todos los nodos del cluster; usa la misma ruta por defecto que ya usan los nodos existentes)" "${HPC_INSTALL_PREFIX}")"
    fi

    echo
    echo -e "${COLOR_BOLD}--- Resumen ---${COLOR_RESET}"
    cat <<EOF
  Nodo:                  ${NODE_NAME}
  IP InfiniBand nodo:    ${NODE_IB_IP}/${IB_NETMASK_CIDR}
  Maestro:               ${MASTER_HOSTNAME} (${MASTER_IB_IP})
  Mascara InfiniBand:    /${IB_NETMASK_CIDR}
  NFS remoto:            ${MASTER_HOSTNAME}:${NFS_EXPORT_PATH} -> ${NFS_MOUNT_POINT}
  NFS sobre RDMA:        ${DO_NFS_RDMA}
  Usuario/grupo cluster: ${CLUSTER_USER}:${CLUSTER_GROUP}
  apt upgrade:           ${DO_APT_UPGRADE}
  Mitigaciones Ryzen:    ${DO_RYZEN_CSTATE_FIX}
  PCIe ACS override:     ${DO_PCIE_ACS_OVERRIDE}
  Copiar llave a master: ${DO_SSH_COPY_TO_MASTER}
  Editar exports remoto: ${DO_REMOTE_EXPORTS}
  Montar NFS:            ${DO_MOUNT_NFS}
  Buscar libs descargadas: ${DO_CHECK_DOWNLOADS} ${DOWNLOADS_DIR:+(${DOWNLOADS_DIR}, prefix=${HPC_INSTALL_PREFIX})}
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
    mkdir -p /etc/udev/rules.d
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

    pkg_install linux-tools-common "linux-tools-$(uname -r)" cpufrequtils numactl hwloc-nox

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

    if [[ "${DO_RYZEN_CSTATE_FIX}" == true || "${DO_PCIE_ACS_OVERRIDE}" == true ]]; then
        if [[ -f /etc/default/grub ]]; then
            backup_file /etc/default/grub
            local extra_params=""
            [[ "${DO_RYZEN_CSTATE_FIX}" == true ]] && extra_params="processor.max_cstate=1 idle=nomwait"
            if [[ "${DO_PCIE_ACS_OVERRIDE}" == true ]]; then
                extra_params="${extra_params}${extra_params:+ }pcie_acs_override=downstream,multifunction"
            fi
            if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
                for param in ${extra_params}; do
                    local param_name="${param%%=*}"
                    if ! grep -q "${param_name}" /etc/default/grub; then
                        sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"(.*)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${param}\"|" /etc/default/grub
                    fi
                done
            else
                echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${extra_params}\"" >> /etc/default/grub
            fi
            update-grub 2>&1 | tee -a "${LOG_FILE}" || warn "update-grub fallo; revisa /etc/default/grub manualmente."
            ok "Parametros de kernel agregados a GRUB: ${extra_params} (requieren reinicio)."
            if [[ "${DO_RYZEN_CSTATE_FIX}" == true ]]; then
                warn "'processor.max_cstate=1 idle=nomwait' es un workaround conocido para congelamientos por estados C profundos en plataformas AMD Ryzen/Threadripper. Si el problema persiste, revisa tambien en la BIOS: 'Global C-State Control' / 'Core C6 State' -> Disabled, y actualiza el firmware/BIOS de la board."
            fi
            if [[ "${DO_PCIE_ACS_OVERRIDE}" == true ]]; then
                warn "'pcie_acs_override=downstream,multifunction' mejora el trafico peer-to-peer (InfiniBand/GPUs) en Threadripper, a costa de relajar el aislamiento IOMMU entre dispositivos."
            fi
        else
            warn "No se encontro /etc/default/grub (¿este sistema no usa GRUB?). Omite el ajuste de parametros de kernel."
        fi
    fi

    # Topologia NUMA/CCX: en el 2990WX (4 dies, solo 2 con memoria conectada
    # directamente) y, en menor medida, en el 1950X, el rendimiento y la
    # estabilidad de MPI/OpenMP mejoran mucho si los hilos se atan a nucleos
    # cercanos a la memoria que usan. 'numactl --hardware' / 'lstopo' (de
    # hwloc) sirven para verificar la topologia real; los ajustes de
    # afinidad correspondientes se dejan declarados en ~/.bashrc del usuario
    # del cluster (etapa de variables de entorno, mas adelante). En la BIOS
    # del 2990WX conviene ademas revisar 'NUMA nodes per socket' = 4 (Die)
    # para que el sistema operativo vea la topologia real de memoria.
    if command -v numactl >/dev/null 2>&1; then
        info "Topologia NUMA detectada:"
        numactl --hardware 2>&1 | tee -a "${LOG_FILE}"
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
ib_cm
ib_ucm
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
    info "Todo se instalara en el mismo prefijo (${HPC_INSTALL_PREFIX}) para que coincida con la ruta usada en los demas nodos del cluster."

    pkg_install build-essential gfortran automake autoconf libtool pkg-config cmake

    local ucx_tar
    ucx_tar="$(find_downloaded_archive "${downloads_dir}" "ucx")"
    if [[ -n "${ucx_tar}" ]] && confirm "Se encontro '$(basename "${ucx_tar}")'. ¿Compilarlo e instalarlo en ${HPC_INSTALL_PREFIX} en vez del UCX del repositorio?" "s"; then
        if build_from_source "UCX" "${ucx_tar}" "${HPC_INSTALL_PREFIX}" --with-verbs; then
            UCX_BUILT_FROM_SOURCE=true
            ok "UCX compilado e instalado en ${HPC_INSTALL_PREFIX}."
        else
            warn "Fallo la compilacion de UCX; se usara el paquete del repositorio para OpenMPI."
        fi
    fi

    local ofi_tar
    ofi_tar="$(find_downloaded_archive "${downloads_dir}" "libfabric")"
    if [[ -n "${ofi_tar}" ]] && confirm "Se encontro '$(basename "${ofi_tar}")'. ¿Compilarlo e instalarlo en ${HPC_INSTALL_PREFIX} (proveedor OFI/libfabric alternativo para OpenMPI)?" "s"; then
        if build_from_source "libfabric" "${ofi_tar}" "${HPC_INSTALL_PREFIX}" --enable-verbs; then
            LIBFABRIC_BUILT_FROM_SOURCE=true
            ok "libfabric compilado e instalado en ${HPC_INSTALL_PREFIX}."
        else
            warn "Fallo la compilacion de libfabric; se omite (OpenMPI seguira usando UCX/verbs)."
        fi
    fi

    local libxc_tar
    libxc_tar="$(find_downloaded_archive "${downloads_dir}" "libxc")"
    if [[ -n "${libxc_tar}" ]] && confirm "Se encontro '$(basename "${libxc_tar}")'. ¿Compilarlo e instalarlo en ${HPC_INSTALL_PREFIX} (lo usara luego Quantum ESPRESSO)?" "s"; then
        if build_from_source "LibXC" "${libxc_tar}" "${HPC_INSTALL_PREFIX}"; then
            LIBXC_BUILT_FROM_SOURCE=true
            ok "LibXC compilado e instalado en ${HPC_INSTALL_PREFIX}."
        else
            warn "Fallo la compilacion de LibXC; se puede instalar mas adelante junto con Quantum ESPRESSO."
        fi
    fi

    local ompi_tar
    ompi_tar="$(find_downloaded_archive "${downloads_dir}" "openmpi")"
    if [[ -n "${ompi_tar}" ]] && confirm "Se encontro '$(basename "${ompi_tar}")'. ¿Compilarlo e instalarlo en ${HPC_INSTALL_PREFIX} usando el UCX/libfabric recien compilados (recomendado para InfiniBand)?" "s"; then
        local ompi_args=(--with-verbs)
        [[ "${UCX_BUILT_FROM_SOURCE}" == true ]] && ompi_args+=(--with-ucx="${HPC_INSTALL_PREFIX}")
        [[ "${LIBFABRIC_BUILT_FROM_SOURCE}" == true ]] && ompi_args+=(--with-ofi="${HPC_INSTALL_PREFIX}")
        if build_from_source "OpenMPI" "${ompi_tar}" "${HPC_INSTALL_PREFIX}" "${ompi_args[@]}"; then
            OPENMPI_BUILT_FROM_SOURCE=true
            ok "OpenMPI compilado e instalado en ${HPC_INSTALL_PREFIX}."
        else
            warn "Fallo la compilacion de OpenMPI; se usara el paquete openmpi-bin del repositorio."
        fi
    elif [[ "${UCX_BUILT_FROM_SOURCE}" == true || "${LIBFABRIC_BUILT_FROM_SOURCE}" == true ]]; then
        warn "Se compilaron UCX/libfabric manualmente pero OpenMPI se instalara desde el repositorio y no aprovechara esas bibliotecas. Si quieres que las use, descarga tambien el tarball de OpenMPI y vuelve a ejecutar el script."
    fi

    ldconfig

    {
        echo "HPC_INSTALL_PREFIX=${HPC_INSTALL_PREFIX}"
        echo "UCX_BUILT_FROM_SOURCE=${UCX_BUILT_FROM_SOURCE}"
        echo "LIBFABRIC_BUILT_FROM_SOURCE=${LIBFABRIC_BUILT_FROM_SOURCE}"
        echo "LIBXC_BUILT_FROM_SOURCE=${LIBXC_BUILT_FROM_SOURCE}"
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

    # La interfaz de red asociada a la tarjeta InfiniBand no siempre se llama
    # "ib0": con el esquema de nombres predecibles de systemd/udev puede
    # llamarse algo como "ibp65s0" (bus/slot PCI). La forma confiable de
    # encontrarla, sea cual sea su nombre, es mirar que netdev esta asociado
    # al dispositivo InfiniBand en sysfs, en vez de adivinar por regex.
    local ib_iface=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
        ib_iface="$(ls /sys/class/infiniband/*/device/net/ 2>/dev/null | head -n1)"
        [[ -z "${ib_iface}" ]] && ib_iface="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(ib[0-9]+|ibp[0-9]+s[0-9]+(f[0-9]+)?)$' | head -n1)"
        [[ -n "${ib_iface}" ]] && break
        sleep 1
    done

    if [[ -z "${ib_iface}" ]]; then
        err "No se encontro ninguna interfaz de red asociada a un dispositivo InfiniBand. El modulo mlx5_ib puede no haber podido inicializar la tarjeta. Revisa 'dmesg | grep -i mlx5', 'lspci | grep -i mellanox' y 'ls /sys/class/infiniband/'."
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
    mkdir -p /etc/udev/rules.d
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
    # Ojo con el orden: mkdir/chmod se ejecutan como root, asi que el
    # directorio queda dueno de root con permisos 700 (nadie mas puede
    # entrar). Hay que darle el directorio al usuario del cluster ANTES de
    # invocar "sudo -u ... ssh-keygen", o ese comando falla por permisos al
    # intentar escribir alli.
    chown "${CLUSTER_USER}:${CLUSTER_GROUP}" "${ssh_dir}"

    if [[ ! -f "${ssh_dir}/id_ed25519" ]]; then
        if sudo -u "${CLUSTER_USER}" ssh-keygen -t ed25519 -N "" -f "${ssh_dir}/id_ed25519" -C "${CLUSTER_USER}@${NODE_NAME}"; then
            ok "Par de llaves SSH generado para ${CLUSTER_USER}."
        else
            err "No se pudo generar el par de llaves SSH para ${CLUSTER_USER} (¿falta 'openssh-client'?)."
            return 1
        fi
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

    # Asegura que el cliente NFS quede operativo desde el arranque (antes de
    # que nadie inicie sesion), tanto para este nodo como para el maestro
    # cuando actua como cliente de otro recurso.
    systemctl enable --now rpcbind 2>&1 | tee -a "${LOG_FILE}" || true
    systemctl enable remote-fs.target 2>&1 | tee -a "${LOG_FILE}" || true

    mkdir -p "${NFS_MOUNT_POINT}"

    local nfs_opts="defaults,_netdev,noatime,rsize=1048576,wsize=1048576"
    if [[ "${DO_NFS_RDMA}" == true ]]; then
        # xprtrdma es el modulo cliente que permite montar por RDMA en vez
        # de TCP/IPoIB; en el maestro (servidor) se necesita "svcrdma" y
        # 'echo rdma 20049 > /proc/fs/nfsd/portlist' (ver etapa de exports).
        modprobe xprtrdma 2>>"${LOG_FILE}" && info "Modulo cargado: xprtrdma" || warn "No se pudo cargar xprtrdma; el montaje por RDMA probablemente fallara."
        append_once /etc/modules-load.d/hpc-infiniband.conf "xprtrdma"
        nfs_opts="_netdev,noatime,rsize=1048576,wsize=1048576,rdma,port=20049"
        info "Montando por NFS/RDMA (puerto 20049)."
    fi

    local fstab_line="${MASTER_HOSTNAME}:${NFS_EXPORT_PATH}  ${NFS_MOUNT_POINT}  nfs  ${nfs_opts}  0  0"
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
# 13b. Directorio compartido del cluster: hosts + llaves SSH entre nodos
# ============================================================================

stage_cluster_registry() {
    step "Registrando este nodo en el directorio compartido del cluster (hosts + llaves SSH entre todos los nodos)"

    if [[ "${DO_MOUNT_NFS}" != true ]] || ! mountpoint -q "${NFS_MOUNT_POINT}" 2>/dev/null; then
        warn "El recurso NFS compartido no esta montado; se omite el registro entre nodos (este nodo solo quedara conectado al maestro)."
        return 0
    fi

    local registry_dir="${NFS_MOUNT_POINT}/cluster-conf"
    if ! mkdir -p "${registry_dir}" 2>/dev/null; then
        warn "No se pudo crear ${registry_dir} (¿permisos de escritura en el NFS?); se omite el registro entre nodos."
        return 0
    fi

    local hosts_pool="${registry_dir}/hosts.cluster"
    local keys_pool="${registry_dir}/authorized_keys.pool"
    touch "${hosts_pool}" "${keys_pool}"

    # Si el directorio compartido esta vacio (primer nodo que usa esta
    # version del script), ofrece registrar ahora los nodos que ya existen
    # en el cluster para que este nodo (y los siguientes) los reconozcan.
    if [[ ! -s "${hosts_pool}" ]]; then
        info "El directorio compartido de nodos esta vacio todavia."
        if confirm "¿Registrar ahora los nodos que ya existen en el cluster (nombre e IP InfiniBand de cada uno)?" "s"; then
            while true; do
                local peer_name peer_ip
                peer_name="$(ask "Nombre del nodo existente (dejar vacio para terminar)" "")"
                [[ -z "${peer_name}" ]] && break
                peer_ip="$(ask "IP InfiniBand de '${peer_name}'")"
                echo -e "${peer_ip}\t${peer_name}" >> "${hosts_pool}"
            done
        fi
    fi

    # Auto-registro de este nodo (tambien sirve para "auto-encontrarse" y
    # poder hacer pruebas de redundancia consigo mismo).
    grep -qF "${NODE_IB_IP}" "${hosts_pool}" || echo -e "${NODE_IB_IP}\t${NODE_NAME}" >> "${hosts_pool}"

    local user_home
    user_home="$(getent passwd "${CLUSTER_USER}" | cut -d: -f6)"
    local pubkey_file="${user_home}/.ssh/id_ed25519.pub"
    if [[ -f "${pubkey_file}" ]] && ! grep -qF "$(cat "${pubkey_file}")" "${keys_pool}" 2>/dev/null; then
        cat "${pubkey_file}" >> "${keys_pool}"
    fi

    # Fusiona el directorio compartido con este nodo: /etc/hosts y
    # authorized_keys, para que cada nodo reconozca (y confie via SSH,
    # necesario para que "mpirun --host nodo1,nodo2,..." funcione de forma
    # directa entre nodos y no solo a traves del maestro) a todos los
    # demas, incluyendose a si mismo.
    backup_file /etc/hosts
    while IFS=$'\t' read -r ip name; do
        [[ -z "${ip}" || -z "${name}" ]] && continue
        append_once /etc/hosts "${ip}	${name}"
    done < "${hosts_pool}"
    ok "/etc/hosts sincronizado con el directorio compartido del cluster ($(grep -c . "${hosts_pool}") nodo(s) registrados)."

    local authorized_keys="${user_home}/.ssh/authorized_keys"
    touch "${authorized_keys}"
    while read -r line; do
        [[ -z "${line}" ]] && continue
        grep -qF "${line}" "${authorized_keys}" || echo "${line}" >> "${authorized_keys}"
    done < "${keys_pool}"
    chown "${CLUSTER_USER}:${CLUSTER_GROUP}" "${authorized_keys}"
    chmod 600 "${authorized_keys}"
    ok "Llaves SSH de todos los nodos registrados fusionadas en authorized_keys (confianza SSH mutua entre nodos, incluido este nodo consigo mismo)."

    local known_hosts="${user_home}/.ssh/known_hosts"
    touch "${known_hosts}"
    while IFS=$'\t' read -r ip name; do
        [[ -z "${ip}" ]] && continue
        timeout 5 ssh-keyscan -H "${ip}" >> "${known_hosts}" 2>/dev/null
    done < "${hosts_pool}"
    sort -u -o "${known_hosts}" "${known_hosts}"
    chown "${CLUSTER_USER}:${CLUSTER_GROUP}" "${known_hosts}"

    warn "Los nodos que ya existian ANTES de esta version del script no aparecen aqui automaticamente salvo que los hayas registrado en el paso anterior; para que reconozcan a este nodo nuevo, vuelve a ejecutar esta misma etapa en ellos (o este script completo) una vez que este nodo ya este en el directorio compartido."
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
        if [[ "${DO_NFS_RDMA}" == true ]]; then
            cat <<EOF
Para que el maestro tambien acepte NFS por RDMA, en el MAESTRO:

  sudo modprobe svcrdma
  sudo sh -c 'echo rdma 20049 > /proc/fs/nfsd/portlist'

(despues de que nfs-kernel-server ya este arriba; conviene dejarlo tambien
en un servicio/udev rule para que se repita en cada arranque del maestro).

EOF
        fi
        return 0
    fi

    local export_line="${NFS_EXPORT_PATH} ${NODE_IB_IP}(rw,sync,no_subtree_check,no_root_squash)"
    local remote_cmd="grep -qF '${NODE_IB_IP}' /etc/exports 2>/dev/null || echo '${export_line}' | sudo tee -a /etc/exports >/dev/null; sudo exportfs -ra"

    if sudo -u "${CLUSTER_USER}" ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${CLUSTER_USER}@${MASTER_IB_IP}" "${remote_cmd}" 2>&1 | tee -a "${LOG_FILE}"; then
        ok "El maestro ahora exporta ${NFS_EXPORT_PATH} para ${NODE_IB_IP}."
    else
        warn "No se pudo modificar /etc/exports en el maestro automaticamente (¿el usuario ${CLUSTER_USER} tiene sudo alli y la llave SSH quedo instalada?). Hazlo manualmente con la linea mostrada arriba."
    fi

    if [[ "${DO_NFS_RDMA}" == true ]]; then
        local rdma_cmd="sudo modprobe svcrdma; grep -qF '20049' /proc/fs/nfsd/portlist 2>/dev/null || sudo sh -c 'echo rdma 20049 > /proc/fs/nfsd/portlist'"
        if sudo -u "${CLUSTER_USER}" ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${CLUSTER_USER}@${MASTER_IB_IP}" "${rdma_cmd}" 2>&1 | tee -a "${LOG_FILE}"; then
            ok "El maestro quedo escuchando NFS/RDMA en el puerto 20049."
        else
            warn "No se pudo activar NFS/RDMA en el maestro automaticamente. Hazlo manualmente alli: 'sudo modprobe svcrdma' y 'echo rdma 20049 | sudo tee /proc/fs/nfsd/portlist' (con nfs-kernel-server ya arrancado)."
        fi
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
        info "OpenMPI ya fue compilado desde el tarball descargado (etapa anterior) en ${HPC_INSTALL_PREFIX}; se omiten los paquetes openmpi-bin/libucx del repositorio para evitar que convivan dos instalaciones distintas."
        hash -r
    else
        # OpenMPI es el que habilita la comunicacion entre nodos (y usara los
        # verbs de InfiniBand automaticamente si UCX/ibverbs estan presentes).
        pkg_install openmpi-bin openmpi-common libopenmpi-dev libucx0 libucx-dev ucx-utils
        ok "OpenMPI (repositorio) instalado; la preferencia por UCX/InfiniBand se declara en ~/.bashrc en la siguiente etapa."
    fi

    if [[ "${LIBXC_BUILT_FROM_SOURCE}" == true ]]; then
        info "LibXC ya esta compilado en ${HPC_INSTALL_PREFIX}, listo para cuando instales Quantum ESPRESSO."
    elif apt-cache show libxc-dev >/dev/null 2>&1; then
        pkg_install libxc-dev
        info "libxc-dev instalado desde el repositorio como base minima para Quantum ESPRESSO."
    fi

    if command -v mpirun >/dev/null 2>&1; then
        info "$(mpirun --version | head -n1)"
    fi
}

# ============================================================================
# 16. Variables de entorno en ~/.bashrc (interactivo y NO interactivo)
# ============================================================================

stage_bashrc_environment() {
    step "Publicando variables de entorno en ~/.bashrc (para terminales y para mpirun via SSH)"

    local user_home
    user_home="$(getent passwd "${CLUSTER_USER}" | cut -d: -f6)"
    local bashrc_file="${user_home}/.bashrc"

    local env_block
    env_block="$(cat <<EOF
# Rutas del stack HPC (UCX/OpenMPI/libfabric/LibXC). Este prefijo debe ser
# IGUAL en todos los nodos del cluster.
export HPC_PREFIX="${HPC_INSTALL_PREFIX}"
export PATH="\${HPC_PREFIX}/bin:\${PATH}"
# LIBRARY_PATH es lo que usa gcc/gfortran en tiempo de COMPILACION/enlace
# para encontrar -lucx, -lfabric, etc. sin necesitar -L explicito.
export LIBRARY_PATH="\${HPC_PREFIX}/lib:\${LIBRARY_PATH:-}"
# UCX carga sus modulos de transporte (verbs, shared memory, etc.) desde un
# subdirectorio "ucx/" propio, no solo desde el lib/ general; si no esta en
# el path puede perder silenciosamente el soporte de InfiniBand y caer a
# TCP. Se incluyen ambas rutas (la del stack compilado y la del paquete
# libucx0 de Ubuntu/Mint) para cubrir los dos casos.
export LD_LIBRARY_PATH="\${HPC_PREFIX}/lib:\${HPC_PREFIX}/lib/ucx:/usr/lib/ucx:\${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="\${HPC_PREFIX}/lib/pkgconfig:\${PKG_CONFIG_PATH:-}"

# MPI sobre InfiniBand: preferir UCX (usa los verbs de Mellanox/mlx5) entre
# nodos y memoria compartida dentro de un mismo nodo.
export OMPI_MCA_pml=ucx
export OMPI_MCA_btl=self,vader

# Afinidad de nucleos para AMD Ryzen/Threadripper (1950X de 16 nucleos,
# 2990WX de 32 nucleos): atar cada proceso/hilo a nucleos concretos evita
# que el planificador los mueva entre CCX/dies con memoria remota, lo cual
# en el 2990WX en particular (solo 2 de sus 4 dies tienen memoria conectada
# directamente) puede ser bastante mas lento. Revisa la topologia real con
# 'numactl --hardware' o 'lstopo' antes de lanzar trabajos grandes.
export OMP_PROC_BIND=close
export OMP_PLACES=cores
export OMPI_MCA_hwloc_base_binding_policy=core

# Intel MKL / oneAPI: se activa solo si ya esta instalado (lo instalas tu
# mismo mas adelante junto con Quantum ESPRESSO). Se prueba primero la ruta
# especifica del componente MKL (mas liviana) y se cae al setvars.sh general
# solo si no existe; NUNCA se activan los componentes de MPI/compilador de
# Intel para no chocar con OpenMPI/gcc, que es lo que usa este cluster.
if [ -f /opt/intel/oneapi/mkl/latest/env/vars.sh ]; then
    source /opt/intel/oneapi/mkl/latest/env/vars.sh > /dev/null 2>&1
elif [ -f /opt/intel/oneapi/setvars.sh ]; then
    # Respaldo: activa todo oneAPI (incluye MPI/compiladores de Intel si
    # estan instalados). Si eso llega a chocar con OpenMPI/gcc en el PATH,
    # instala solo el componente MKL para que la rama de arriba lo detecte.
    source /opt/intel/oneapi/setvars.sh --force > /dev/null 2>&1
elif [ -f /opt/intel/mkl/bin/mklvars.sh ]; then
    source /opt/intel/mkl/bin/mklvars.sh intel64 > /dev/null 2>&1
fi

# MKL_CBWR (Conditional Bitwise Reproducibility, antes llamado "CNR"): fuerza
# a MKL a usar siempre la MISMA ruta de codigo en vez de la que el CPU
# detecte en cada corrida, para que dos ejecuciones (incluso en nodos
# distintos) den resultados numericamente identicos bit a bit. AUTO deja
# que MKL elija la ruta optima sin forzar reproducibilidad (equivalente a
# tenerlo desactivado); cambialo a un valor fijo (p.ej. AVX2) si necesitas
# que dos nodos den exactamente el mismo resultado en Quantum ESPRESSO.
export MKL_CBWR=AUTO

# Instrucciones vectoriales que MKL tiene PERMITIDO usar como maximo (nunca
# fuerza una ruta de codigo incorrecta: solo pone un techo). En el
# 1950X/2990WX (Zen1/Zen+, sin AVX-512) el techo real de hardware es AVX2.
# Es el reemplazo actual de MKL_DEBUG_CPU_TYPE, que Intel desactivo hace
# varios anios (hoy no tiene ningun efecto, por eso no se incluye aqui).
# Aun asi, en CPUs no-Intel el beneficio no esta garantizado: Intel no
# promete el despacho optimo fuera de sus propios procesadores.
export MKL_ENABLE_INSTRUCTIONS=AVX2

# Evita que MKL cargue su PROPIO runtime de OpenMP (libiomp5) por separado
# del que usan gcc/gfortran (libgomp, via -fopenmp). Tener dos runtimes de
# OpenMP activos a la vez en el mismo proceso es una causa real y conocida
# de sobre-suscripcion de nucleos y cuelgues en codigos hibridos MPI+OpenMP
# que llaman a MKL (como Quantum ESPRESSO). Como este cluster compila con
# gcc/gfortran (no con los compiladores de Intel), "GNU" es la opcion
# correcta aqui.
export MKL_THREADING_LAYER=GNU

# A PROPOSITO no se fija aqui un numero de hilos fijo para MKL
# (MKL_NUM_THREADS / MKL_DYNAMIC=FALSE): el valor correcto depende de
# cuantos procesos MPI por nodo uses en cada corrida (p.ej. un solo rango
# usando todos los nucleos vs. varios rangos con pocos hilos cada uno).
# Fijarlo aqui de forma global, igual para toda corrida, es exactamente el
# tipo de ajuste "demasiado especifico" que puede sobre-suscribir los
# nucleos y pisarse con el paralelismo de OpenMPI/OpenMP: ajusta
# OMP_NUM_THREADS (y MKL_NUM_THREADS si hace falta) en el script de cada
# trabajo especifico, no en este archivo. Por la misma razon tampoco se
# toca MKL_INTERFACE_LAYER (LP64/ILP64): debe coincidir exactamente con
# como se compilo/enlazo cada programa, no es algo que se pueda fijar de
# forma general para todo el sistema.
EOF
)"

    inject_bashrc_block "${bashrc_file}" "${env_block}"
    chown "${CLUSTER_USER}:${CLUSTER_GROUP}" "${bashrc_file}"
    ok "Bloque de entorno insertado al PRINCIPIO de ${bashrc_file} (antes del guardian de shells no interactivas), para que tanto una terminal como 'mpirun ... --host otro_nodo' via SSH vean las mismas rutas."
}

# ============================================================================
# 17. Resumen final
# ============================================================================

final_summary() {
    echo
    echo -e "${COLOR_BOLD}${COLOR_GREEN}=== Configuracion del nodo '${NODE_NAME}' finalizada ===${COLOR_RESET}"
    echo
    echo "Resumen de red InfiniBand:"
    echo "  Tarjeta detectada: ${IB_CARD_PRESENT}"
    echo "  Interfaz:        ${IB_IFACE:-no detectada}"
    echo "  IP de este nodo: ${NODE_IB_IP}/${IB_NETMASK_CIDR}"
    echo "  Maestro:         ${MASTER_HOSTNAME} (${MASTER_IB_IP})"
    echo "  Recurso NFS:     ${MASTER_HOSTNAME}:${NFS_EXPORT_PATH} -> ${NFS_MOUNT_POINT} $([[ "${DO_NFS_RDMA}" == true ]] && echo "(RDMA, puerto 20049)" || echo "(TCP)")"
    echo
    echo "Bibliotecas HPC (prefijo comun: ${HPC_INSTALL_PREFIX}):"
    echo "  UCX:       $([[ "${UCX_BUILT_FROM_SOURCE}" == true ]] && echo "compilado en ${HPC_INSTALL_PREFIX}" || echo "repositorio")"
    echo "  libfabric: $([[ "${LIBFABRIC_BUILT_FROM_SOURCE}" == true ]] && echo "compilado en ${HPC_INSTALL_PREFIX}" || echo "no instalado")"
    echo "  LibXC:     $([[ "${LIBXC_BUILT_FROM_SOURCE}" == true ]] && echo "compilado en ${HPC_INSTALL_PREFIX}" || echo "no instalado")"
    echo "  OpenMPI:   $([[ "${OPENMPI_BUILT_FROM_SOURCE}" == true ]] && echo "compilado en ${HPC_INSTALL_PREFIX}" || echo "repositorio")"
    echo
    echo "Directorio compartido del cluster (hosts + llaves SSH entre nodos):"
    echo "  ${NFS_MOUNT_POINT}/cluster-conf/ (si el NFS estaba montado en esta ejecucion)"
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
     en Disabled, y el plan de energia en modo alto rendimiento (en el
     2990WX, tambien 'NUMA nodes per socket' = 4/Die), para complementar
     los ajustes de software aplicados aqui.
  7. Las variables de entorno (MPI, MKL cuando lo instales, afinidad de
     nucleos) ya quedaron en ~${CLUSTER_USER}/.bashrc, activas tanto en una
     terminal como al lanzar 'mpirun --host otro_nodo' via SSH.
  8. Si ya tenias otros nodos en el cluster y no los registraste cuando el
     script te lo pregunto, vuelve a correr este script (o al menos la
     etapa del directorio compartido) en ellos para que reconozcan a este
     nodo nuevo por /etc/hosts y por SSH.

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
    run_stage stage_cluster_registry     "Directorio compartido del cluster"
    run_stage stage_remote_exports       "Exports remotos en el maestro"
    run_stage stage_mpi_toolchain        "Toolchain MPI/OpenMP"
    run_stage stage_bashrc_environment   "Variables de entorno en .bashrc"

    final_summary
}

main "$@"
