#!/usr/bin/env bash
#
# audit-node-config.sh
#
# Compara la configuracion REAL de un nodo (tipicamente uno de los nodos
# antiguos del cluster) contra lo que configure-new-node.sh deja en un nodo
# nuevo, e imprime un reporte de solo lectura: no modifica absolutamente
# nada en el sistema.
#
# Objetivo: permitir decidir, con datos concretos y no a ojo, que tan
# distinta esta la configuracion de un nodo antiguo respecto al estandar
# actual, para poder ir armonizandola de forma gradual y segura (nodo por
# nodo, en ventana de mantenimiento) en vez de "resetear" todo de una vez.
#
# Uso:
#   sudo ./reference/audit-node-config.sh [opciones] > reporte-nodo3.txt
#
# Opciones (todas opcionales; si el nodo ya tiene /etc/hpc-cluster/node.conf
# de una corrida anterior del script, esos valores se usan como base y las
# opciones de abajo los sobrescriben):
#   --user=USUARIO        Usuario estandar del cluster (por defecto: ryzen)
#   --group=GRUPO         Grupo estandar del cluster (por defecto: ryzen)
#   --prefix=RUTA         Prefijo de instalacion HPC (por defecto: /usr/local)
#   --master-host=NOMBRE  Hostname del nodo maestro (por defecto: master)
#   --master-ip=IP        IP InfiniBand del maestro (por defecto: 10.10.10.1)
#
# Salida: una linea por cada verificacion, con una de estas etiquetas:
#   [OK]       coincide con lo que deja configure-new-node.sh
#   [DIFF]     existe pero el valor/contenido difiere
#   [MISSING]  no existe o no esta activo
#   [WARN]     no se pudo verificar (falta el comando, sin permisos, etc.)
#              o es una diferencia esperable que no necesariamente hay que
#              corregir (ver el mensaje)
#   [INFO]     dato informativo, no es una comparacion OK/mal
#
# Al final se imprime un resumen con conteos y la lista de items DIFF/MISSING.
# El codigo de salida es 0 si no hubo ningun DIFF/MISSING, 1 si hubo alguno.
#
# Este script NUNCA instala paquetes, ni edita archivos, ni reinicia
# servicios: solo lee el estado actual del sistema.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="/etc/hpc-cluster/node.conf"

CLUSTER_USER="ryzen"
CLUSTER_GROUP="ryzen"
HPC_INSTALL_PREFIX="/usr/local"
MASTER_HOSTNAME="master"
MASTER_IB_IP="10.10.10.1"

if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    while IFS='=' read -r k v; do
        case "${k}" in
            CLUSTER_USER) CLUSTER_USER="${v}" ;;
            CLUSTER_GROUP) CLUSTER_GROUP="${v}" ;;
            HPC_INSTALL_PREFIX) HPC_INSTALL_PREFIX="${v}" ;;
            MASTER_HOSTNAME) MASTER_HOSTNAME="${v}" ;;
            MASTER_IB_IP) MASTER_IB_IP="${v}" ;;
        esac
    done < "${STATE_FILE}"
fi

for arg in "$@"; do
    case "${arg}" in
        --user=*) CLUSTER_USER="${arg#*=}" ;;
        --group=*) CLUSTER_GROUP="${arg#*=}" ;;
        --prefix=*) HPC_INSTALL_PREFIX="${arg#*=}" ;;
        --master-host=*) MASTER_HOSTNAME="${arg#*=}" ;;
        --master-ip=*) MASTER_IB_IP="${arg#*=}" ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Opcion no reconocida: ${arg}" >&2; exit 2 ;;
    esac
done

COLOR_RESET="\e[0m"; COLOR_RED="\e[31m"; COLOR_GREEN="\e[32m"
COLOR_YELLOW="\e[33m"; COLOR_BLUE="\e[34m"; COLOR_BOLD="\e[1m"

COUNT_OK=0; COUNT_DIFF=0; COUNT_MISSING=0; COUNT_WARN=0; COUNT_INFO=0
declare -a FLAGGED_ITEMS=()

report() {
    # report <OK|DIFF|MISSING|WARN|INFO> <categoria> <mensaje>
    local status="$1" category="$2" message="$3" color label
    case "${status}" in
        OK)      color="${COLOR_GREEN}";  label="[OK]     "; COUNT_OK=$((COUNT_OK+1)) ;;
        DIFF)    color="${COLOR_RED}";    label="[DIFF]   "; COUNT_DIFF=$((COUNT_DIFF+1)); FLAGGED_ITEMS+=("DIFF    ${category} :: ${message}") ;;
        MISSING) color="${COLOR_RED}";    label="[MISSING]"; COUNT_MISSING=$((COUNT_MISSING+1)); FLAGGED_ITEMS+=("MISSING ${category} :: ${message}") ;;
        WARN)    color="${COLOR_YELLOW}"; label="[WARN]   "; COUNT_WARN=$((COUNT_WARN+1)) ;;
        INFO)    color="${COLOR_BLUE}";   label="[INFO]   "; COUNT_INFO=$((COUNT_INFO+1)) ;;
    esac
    printf "%b%s%b %-22s %s\n" "${color}" "${label}" "${COLOR_RESET}" "${category}" "${message}"
}

section() {
    echo
    echo -e "${COLOR_BOLD}${COLOR_BLUE}== $* ==${COLOR_RESET}"
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "^install ok installed"
}

file_contains_all() {
    # file_contains_all <archivo> <linea1> [linea2 ...] -> 0 si el archivo
    # existe y contiene TODAS las lineas dadas (coincidencia exacta de texto).
    local file="$1"; shift
    [[ -f "${file}" ]] || return 2
    local line
    for line in "$@"; do
        grep -qF -- "${line}" "${file}" || return 1
    done
    return 0
}

# ============================================================================
echo -e "${COLOR_BOLD}Auditoria de configuracion de nodo HPC${COLOR_RESET}"
echo "Nodo:              $(hostname)"
echo "Fecha:             $(date -Is)"
echo "Usuario esperado:  ${CLUSTER_USER}:${CLUSTER_GROUP}"
echo "Prefijo HPC:       ${HPC_INSTALL_PREFIX}"
echo "Maestro esperado:  ${MASTER_HOSTNAME} (${MASTER_IB_IP})"
if [[ -f "${STATE_FILE}" ]]; then
    echo "Origen de estos valores: ${STATE_FILE} (este nodo ya corrio el script alguna vez)"
else
    echo "Origen de estos valores: valores por defecto / opciones de linea de comandos (este nodo NO tiene ${STATE_FILE})"
fi
if [[ "${EUID}" -ne 0 ]]; then
    report WARN "permisos" "No se esta ejecutando como root; algunas verificaciones (GRUB, PAM, systemd) pueden salir como [WARN] por falta de permiso de lectura. Se recomienda 'sudo'."
fi

# ---------------------------------------------------------------------------
section "1. Usuario/grupo y autologin"

if id "${CLUSTER_USER}" >/dev/null 2>&1; then
    report OK "usuario" "El usuario '${CLUSTER_USER}' existe."
    user_groups="$(id -nG "${CLUSTER_USER}" 2>/dev/null)"
    for g in "${CLUSTER_GROUP}" sudo nopasswdlogin video audio plugdev; do
        if grep -qw "${g}" <<< "${user_groups}"; then
            report OK "usuario/grupos" "'${CLUSTER_USER}' pertenece al grupo '${g}'."
        else
            report DIFF "usuario/grupos" "'${CLUSTER_USER}' NO pertenece al grupo '${g}' (configure-new-node.sh lo agrega)."
        fi
    done
else
    report MISSING "usuario" "El usuario '${CLUSTER_USER}' no existe en este nodo."
fi

if [[ -f /etc/lightdm/lightdm.conf.d/50-hpc-autologin.conf ]]; then
    if file_contains_all /etc/lightdm/lightdm.conf.d/50-hpc-autologin.conf "autologin-user=${CLUSTER_USER}" "autologin-session=cinnamon"; then
        report OK "autologin" "Autologin de LightDM configurado para '${CLUSTER_USER}' con sesion cinnamon."
    else
        report DIFF "autologin" "Existe 50-hpc-autologin.conf pero con contenido distinto al esperado."
    fi
elif command -v lightdm >/dev/null 2>&1 || dpkg -l 2>/dev/null | grep -qi '^ii.*lightdm'; then
    report MISSING "autologin" "LightDM esta instalado pero no existe /etc/lightdm/lightdm.conf.d/50-hpc-autologin.conf."
else
    report INFO "autologin" "LightDM no parece estar instalado en este nodo (puede usar otro gestor de sesiones)."
fi

# ---------------------------------------------------------------------------
section "2. Estabilidad de Cinnamon (sin bloqueo/suspension/salvapantallas)"

if [[ "$(systemctl get-default 2>/dev/null)" == "graphical.target" ]]; then
    report OK "target-arranque" "El target por defecto de systemd es graphical.target."
else
    report DIFF "target-arranque" "El target por defecto es '$(systemctl get-default 2>/dev/null)', se esperaba graphical.target."
fi

if [[ -f /etc/dconf/db/local.d/00-hpc-node-stability ]]; then
    if file_contains_all /etc/dconf/db/local.d/00-hpc-node-stability \
        "sleep-inactive-ac-type='nothing'" "lock-enabled=false" "idle-delay=uint32 0"; then
        report OK "dconf" "Perfil dconf de estabilidad (00-hpc-node-stability) presente y con el contenido esperado."
    else
        report DIFF "dconf" "00-hpc-node-stability existe pero el contenido difiere del esperado."
    fi
else
    report MISSING "dconf" "No existe /etc/dconf/db/local.d/00-hpc-node-stability."
fi

if [[ -f /etc/dconf/db/local.d/locks/hpc-node-stability ]]; then
    report OK "dconf-locks" "Bloqueo de claves dconf (locks/hpc-node-stability) presente."
else
    report MISSING "dconf-locks" "No existe /etc/dconf/db/local.d/locks/hpc-node-stability."
fi

if [[ -d /etc/X11/xorg.conf.d ]]; then
    if [[ -f /etc/X11/xorg.conf.d/10-hpc-no-dpms.conf ]]; then
        report OK "dpms" "DPMS desactivado a nivel Xorg (10-hpc-no-dpms.conf)."
    else
        report MISSING "dpms" "No existe /etc/X11/xorg.conf.d/10-hpc-no-dpms.conf."
    fi
fi

if dpkg -l 2>/dev/null | grep -qi '^ii.*unattended-upgrades'; then
    if systemctl is-enabled unattended-upgrades.service >/dev/null 2>&1; then
        report DIFF "unattended-upgrades" "El servicio esta instalado y HABILITADO (configure-new-node.sh lo desactiva para evitar reinicios inesperados)."
    else
        report OK "unattended-upgrades" "Instalado pero deshabilitado, como se espera."
    fi
else
    report INFO "unattended-upgrades" "Paquete no instalado."
fi

# ---------------------------------------------------------------------------
section "3. Suspension/hibernacion e inactividad"

masked_ok=true
for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
    state="$(systemctl is-enabled "${t}" 2>&1)"
    if [[ "${state}" == "masked" ]]; then
        report OK "systemd-sleep" "${t} esta enmascarado."
    else
        report DIFF "systemd-sleep" "${t} NO esta enmascarado (estado: ${state})."
        masked_ok=false
    fi
done

if [[ -f /etc/systemd/logind.conf.d/99-hpc-no-sleep.conf ]]; then
    if file_contains_all /etc/systemd/logind.conf.d/99-hpc-no-sleep.conf "HandleLidSwitch=ignore" "IdleAction=ignore"; then
        report OK "logind" "logind configurado para ignorar tapa/inactividad (99-hpc-no-sleep.conf)."
    else
        report DIFF "logind" "99-hpc-no-sleep.conf existe pero el contenido difiere."
    fi
else
    report MISSING "logind" "No existe /etc/systemd/logind.conf.d/99-hpc-no-sleep.conf."
fi

if [[ -f /etc/udev/rules.d/50-hpc-no-usb-autosuspend.rules ]]; then
    report OK "usb-autosuspend" "Regla udev de autosuspend USB presente."
else
    report MISSING "usb-autosuspend" "No existe /etc/udev/rules.d/50-hpc-no-usb-autosuspend.rules."
fi

# ---------------------------------------------------------------------------
section "4. Gobernador de CPU / estados C / GRUB / sysctl"

if [[ -f /usr/local/sbin/hpc-set-cpu-performance.sh ]]; then
    report OK "cpu-governor-script" "Script hpc-set-cpu-performance.sh presente."
else
    report MISSING "cpu-governor-script" "No existe /usr/local/sbin/hpc-set-cpu-performance.sh."
fi

if systemctl is-enabled hpc-cpu-performance.service >/dev/null 2>&1; then
    report OK "cpu-governor-service" "Servicio hpc-cpu-performance.service habilitado."
else
    report MISSING "cpu-governor-service" "Servicio hpc-cpu-performance.service no existe/no esta habilitado."
fi

gov_file="$(ls /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)"
if [[ -n "${gov_file}" ]]; then
    current_gov="$(cat "${gov_file}" 2>/dev/null || echo desconocido)"
    if [[ "${current_gov}" == "performance" ]]; then
        report OK "cpu-governor-actual" "El gobernador de CPU activo ahora mismo es 'performance'."
    else
        report DIFF "cpu-governor-actual" "El gobernador de CPU activo es '${current_gov}', se esperaba 'performance'."
    fi
else
    report WARN "cpu-governor-actual" "No se pudo leer scaling_governor (¿driver de cpufreq no cargado en esta VM/CPU?)."
fi

if [[ -r /etc/default/grub ]]; then
    grub_line="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || true)"
    for param in "processor.max_cstate=1" "idle=nomwait" "pcie_acs_override=downstream,multifunction"; do
        if grep -qF -- "${param}" <<< "${grub_line}"; then
            report OK "grub" "Parametro de kernel '${param}' presente."
        else
            report WARN "grub" "Parametro de kernel '${param}' ausente en GRUB_CMDLINE_LINUX_DEFAULT (opcional segun hardware/plataforma; revisar si aplica a este nodo)."
        fi
    done
else
    report WARN "grub" "No se pudo leer /etc/default/grub (¿permisos? ¿este sistema no usa GRUB?)."
fi

if [[ -f /etc/sysctl.d/99-hpc-stability.conf ]]; then
    if file_contains_all /etc/sysctl.d/99-hpc-stability.conf "vm.swappiness=10" "kernel.panic=10" "kernel.panic_on_oops=1"; then
        report OK "sysctl" "99-hpc-stability.conf presente y con el contenido esperado."
    else
        report DIFF "sysctl" "99-hpc-stability.conf existe pero el contenido difiere del esperado."
    fi
else
    report MISSING "sysctl" "No existe /etc/sysctl.d/99-hpc-stability.conf."
fi

# ---------------------------------------------------------------------------
section "5. Limites de memoria (memlock/nofile) para RDMA"

if [[ -r /etc/security/limits.d/99-hpc-cluster.conf ]]; then
    if file_contains_all /etc/security/limits.d/99-hpc-cluster.conf \
        "${CLUSTER_USER}     soft    memlock   unlimited" \
        "${CLUSTER_USER}     hard    memlock   unlimited" \
        "${CLUSTER_USER}     soft    nofile    1048576"; then
        report OK "limits.d" "99-hpc-cluster.conf presente y con los limites esperados para '${CLUSTER_USER}'."
    else
        report DIFF "limits.d" "99-hpc-cluster.conf existe pero difiere del formato esperado (o el usuario configurado no coincide)."
    fi
else
    report MISSING "limits.d" "No existe /etc/security/limits.d/99-hpc-cluster.conf (o no se pudo leer)."
fi

for pamfile in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    if [[ -r "${pamfile}" ]]; then
        if grep -q "pam_limits.so" "${pamfile}"; then
            report OK "pam_limits" "pam_limits.so presente en ${pamfile}."
        else
            report DIFF "pam_limits" "pam_limits.so NO esta en ${pamfile}."
        fi
    else
        report WARN "pam_limits" "No se pudo leer ${pamfile}."
    fi
done

if [[ -f /etc/systemd/system.conf.d/99-hpc-memlock.conf ]]; then
    report OK "systemd-memlock" "DefaultLimitMEMLOCK=infinity configurado a nivel de systemd."
else
    report MISSING "systemd-memlock" "No existe /etc/systemd/system.conf.d/99-hpc-memlock.conf."
fi

if [[ -f /etc/systemd/system/ssh.service.d/99-hpc-memlock.conf ]]; then
    report OK "ssh-memlock" "LimitMEMLOCK=infinity configurado para el servicio SSH."
else
    report MISSING "ssh-memlock" "No existe /etc/systemd/system/ssh.service.d/99-hpc-memlock.conf."
fi

# ---------------------------------------------------------------------------
section "6. Pila RDMA/InfiniBand"

ib_pkgs=(rdma-core ibverbs-utils ibverbs-providers libibverbs1 librdmacm1 infiniband-diags perftest opensm)
missing_ib_pkgs=()
for p in "${ib_pkgs[@]}"; do
    pkg_installed "${p}" || missing_ib_pkgs+=("${p}")
done
if [[ ${#missing_ib_pkgs[@]} -eq 0 ]]; then
    report OK "ib-paquetes" "Todos los paquetes RDMA/InfiniBand esperados estan instalados."
else
    report DIFF "ib-paquetes" "Faltan paquetes: ${missing_ib_pkgs[*]}."
fi

if [[ -f /etc/modules-load.d/hpc-infiniband.conf ]]; then
    report OK "ib-modules-conf" "/etc/modules-load.d/hpc-infiniband.conf presente."
else
    report MISSING "ib-modules-conf" "No existe /etc/modules-load.d/hpc-infiniband.conf."
fi

if lspci 2>/dev/null | grep -qi mellanox; then
    report INFO "ib-hardware" "Tarjeta Mellanox detectada por PCI en este nodo."
    if lsmod 2>/dev/null | grep -q '^mlx5_core'; then
        report OK "ib-modulo-mlx5" "Modulo mlx5_core cargado."
    else
        report DIFF "ib-modulo-mlx5" "Hay tarjeta Mellanox pero el modulo mlx5_core NO esta cargado."
    fi
else
    report INFO "ib-hardware" "No se detecto tarjeta Mellanox por PCI en este nodo (si es un nodo sin InfiniBand, los items de esta seccion no aplican)."
fi

for svc in rdma-load-modules@rdma.service rdma-ndd; do
    if systemctl is-enabled "${svc}" >/dev/null 2>&1; then
        report OK "ib-servicio" "${svc} habilitado."
    else
        report WARN "ib-servicio" "${svc} no esta habilitado (revisar si aplica; en algunas distros no existe como unidad separada)."
    fi
done

# ---------------------------------------------------------------------------
section "7. Interfaz IPoIB"

ib_iface="$(ls /sys/class/infiniband/*/device/net/ 2>/dev/null | head -n1)"
if [[ -n "${ib_iface}" ]]; then
    report INFO "ipoib-iface" "Interfaz InfiniBand detectada: ${ib_iface}."
    mode_file="/sys/class/net/${ib_iface}/mode"
    if [[ -r "${mode_file}" ]] && [[ "$(cat "${mode_file}")" == "connected" ]]; then
        report OK "ipoib-modo" "Modo 'connected' activo en ${ib_iface}."
    else
        report DIFF "ipoib-modo" "El modo de ${ib_iface} no es 'connected' (o no se pudo leer)."
    fi
    mtu="$(ip -o link show "${ib_iface}" 2>/dev/null | grep -oP 'mtu \K[0-9]+')"
    if [[ "${mtu}" == "65520" ]]; then
        report OK "ipoib-mtu" "MTU de ${ib_iface} es 65520."
    else
        report DIFF "ipoib-mtu" "MTU de ${ib_iface} es '${mtu:-desconocido}', se esperaba 65520."
    fi
    if [[ -f /etc/udev/rules.d/60-hpc-ipoib-mode.rules ]]; then
        report OK "ipoib-udev" "Regla udev que fija modo/MTU de forma persistente esta presente."
    else
        report MISSING "ipoib-udev" "No existe /etc/udev/rules.d/60-hpc-ipoib-mode.rules (el modo/MTU puede no sobrevivir un reinicio)."
    fi
    if command -v nmcli >/dev/null 2>&1 && nmcli -t -f NAME connection show 2>/dev/null | grep -q "^hpc-${ib_iface}$"; then
        report OK "ipoib-nmcli" "Conexion NetworkManager 'hpc-${ib_iface}' presente."
    else
        report WARN "ipoib-nmcli" "No se encontro una conexion NetworkManager 'hpc-${ib_iface}' (puede estar configurada de otra forma en este nodo antiguo)."
    fi
else
    report INFO "ipoib-iface" "No se detecto ninguna interfaz InfiniBand en /sys/class/infiniband; se omite el resto de esta seccion."
fi

# ---------------------------------------------------------------------------
section "8. /etc/hosts, SSH y NFS"

if grep -qE "\\b${MASTER_HOSTNAME}\\b" /etc/hosts 2>/dev/null; then
    report OK "hosts" "/etc/hosts contiene una entrada para '${MASTER_HOSTNAME}'."
else
    report DIFF "hosts" "/etc/hosts NO contiene una entrada para '${MASTER_HOSTNAME}'."
fi
if grep -qE "\\b$(hostname)\\b" /etc/hosts 2>/dev/null; then
    report OK "hosts" "/etc/hosts contiene una entrada para este mismo nodo ($(hostname))."
else
    report DIFF "hosts" "/etc/hosts NO contiene una entrada para este mismo nodo ($(hostname))."
fi

if systemctl is-active ssh >/dev/null 2>&1 || systemctl is-active sshd >/dev/null 2>&1; then
    report OK "ssh" "El servicio SSH esta activo."
else
    report DIFF "ssh" "El servicio SSH no esta activo."
fi

user_home="$(getent passwd "${CLUSTER_USER}" 2>/dev/null | cut -d: -f6)"
if [[ -n "${user_home}" ]]; then
    if [[ -f "${user_home}/.ssh/id_ed25519" ]]; then
        report OK "ssh-keys" "Par de llaves ed25519 presente para '${CLUSTER_USER}'."
    else
        report DIFF "ssh-keys" "No hay llave ed25519 en ${user_home}/.ssh/ para '${CLUSTER_USER}' (puede tener otro tipo de llave; revisar manualmente)."
    fi
    if [[ -s "${user_home}/.ssh/authorized_keys" ]]; then
        report OK "ssh-authorized_keys" "authorized_keys no esta vacio."
    else
        report WARN "ssh-authorized_keys" "authorized_keys no existe o esta vacio."
    fi
fi

if pkg_installed nfs-common; then
    report OK "nfs-paquete" "nfs-common instalado."
else
    report DIFF "nfs-paquete" "nfs-common NO esta instalado."
fi
if systemctl is-enabled rpcbind >/dev/null 2>&1; then
    report OK "nfs-rpcbind" "rpcbind habilitado."
else
    report DIFF "nfs-rpcbind" "rpcbind no esta habilitado."
fi
if systemctl is-enabled remote-fs.target >/dev/null 2>&1; then
    report OK "nfs-remote-fs" "remote-fs.target habilitado."
else
    report WARN "nfs-remote-fs" "remote-fs.target no aparece habilitado explicitamente."
fi
if grep -qE "^${MASTER_HOSTNAME}:" /etc/fstab 2>/dev/null; then
    fstab_mount="$(grep -E "^${MASTER_HOSTNAME}:" /etc/fstab | awk '{print $2}' | head -n1)"
    report OK "nfs-fstab" "Entrada de fstab para ${MASTER_HOSTNAME} presente (punto de montaje: ${fstab_mount})."
    if mountpoint -q "${fstab_mount}" 2>/dev/null; then
        report OK "nfs-montado" "${fstab_mount} esta montado ahora mismo."
    else
        report DIFF "nfs-montado" "${fstab_mount} NO esta montado ahora mismo (revisar 'mount -a' y conectividad con el maestro)."
    fi
else
    report DIFF "nfs-fstab" "No hay entrada en /etc/fstab para ${MASTER_HOSTNAME}:... (el nodo puede estar usando otra ruta/otro maestro; revisar manualmente)."
fi

if [[ -n "${fstab_mount:-}" && -d "${fstab_mount}/cluster-conf" ]]; then
    report OK "cluster-registry" "Directorio compartido cluster-conf/ presente en el NFS montado."
else
    report WARN "cluster-registry" "No se encontro cluster-conf/ en el punto de montaje NFS (puede que este nodo nunca haya corrido esta version del script)."
fi

# ---------------------------------------------------------------------------
section "9. Toolchain MPI/OpenMP y bibliotecas HPC"

for p in build-essential gfortran cmake pkg-config; do
    if pkg_installed "${p}"; then
        report OK "mpi-toolchain" "${p} instalado."
    else
        report DIFF "mpi-toolchain" "${p} NO esta instalado."
    fi
done

if command -v mpirun >/dev/null 2>&1; then
    mpi_path="$(command -v mpirun)"
    if [[ "${mpi_path}" == "${HPC_INSTALL_PREFIX}"/* ]]; then
        report OK "mpi-openmpi" "mpirun encontrado en ${mpi_path} (dentro del prefijo esperado ${HPC_INSTALL_PREFIX})."
    else
        report INFO "mpi-openmpi" "mpirun encontrado en ${mpi_path} (paquete del repositorio, no compilado desde fuente en ${HPC_INSTALL_PREFIX}; esto es valido, solo informativo)."
    fi
    report INFO "mpi-version" "$(mpirun --version 2>/dev/null | head -n1)"
else
    report MISSING "mpi-openmpi" "No se encontro 'mpirun' en el PATH."
fi

for lib in "ucx" "libfabric" "openmpi"; do
    if [[ -d "${HPC_INSTALL_PREFIX}/lib" ]] && find "${HPC_INSTALL_PREFIX}" -maxdepth 3 -iname "*${lib}*" 2>/dev/null | grep -q .; then
        report INFO "hpc-libs-fuente" "Hay rastros de '${lib}' compilado en ${HPC_INSTALL_PREFIX} (verificar a mano si coincide version con los demas nodos)."
    fi
done

# ---------------------------------------------------------------------------
section "10. Variables de entorno (~/.bashrc)"

if [[ -n "${user_home:-}" ]]; then
    bashrc_checker="${SCRIPT_DIR}/check-bashrc-integrity.sh"
    if [[ -x "${bashrc_checker}" ]]; then
        bashrc_out="$("${bashrc_checker}" "${CLUSTER_USER}" 2>&1)"
        bashrc_status=$?
        case "${bashrc_status}" in
            0) report OK "bashrc" "El bloque de variables de entorno coincide con el patron de referencia (ver reference/check-bashrc-integrity.sh)." ;;
            1) report DIFF "bashrc" "El bloque de variables de entorno DIFIERE del patron de referencia (correr 'sudo ${bashrc_checker} ${CLUSTER_USER}' para ver el diff completo)." ;;
            2) report MISSING "bashrc" "No se encontro el bloque de variables de entorno en ~${CLUSTER_USER}/.bashrc." ;;
        esac
    else
        if grep -qF "hpc-cluster-new-nodes-script" "${user_home}/.bashrc" 2>/dev/null; then
            report OK "bashrc" "El .bashrc de '${CLUSTER_USER}' tiene el bloque marcado (no se pudo comparar el contenido exacto: falta reference/check-bashrc-integrity.sh junto a este script)."
        else
            report MISSING "bashrc" "El .bashrc de '${CLUSTER_USER}' no tiene el bloque de variables de entorno del cluster."
        fi
    fi
fi

# ============================================================================
section "Resumen"

echo "OK:      ${COUNT_OK}"
echo "DIFF:    ${COUNT_DIFF}"
echo "MISSING: ${COUNT_MISSING}"
echo "WARN:    ${COUNT_WARN}"
echo "INFO:    ${COUNT_INFO}"

if [[ ${#FLAGGED_ITEMS[@]} -gt 0 ]]; then
    echo
    echo -e "${COLOR_BOLD}Items que difieren del estandar del nodo nuevo (DIFF/MISSING):${COLOR_RESET}"
    for item in "${FLAGGED_ITEMS[@]}"; do
        echo "  - ${item}"
    done
    exit 1
else
    echo
    echo -e "${COLOR_GREEN}${COLOR_BOLD}Este nodo coincide con el estandar del nodo nuevo en todo lo verificado.${COLOR_RESET}"
    exit 0
fi
