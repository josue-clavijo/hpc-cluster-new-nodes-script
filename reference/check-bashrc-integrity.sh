#!/usr/bin/env bash
#
# check-bashrc-integrity.sh
#
# Compara el bloque que configure-new-node.sh inserta en ~/.bashrc contra el
# patron de referencia (expected-bashrc-block.sh, en esta misma carpeta),
# para detectar si algo lo modifico, lo corrompio, o le inyecto codigo
# inesperado despues de que el script termino.
#
# Uso:
#   sudo ./reference/check-bashrc-integrity.sh [usuario]
#
# Sin argumento usa el usuario guardado en /etc/hpc-cluster/node.conf
# (CLUSTER_USER), o "ryzen" si no lo encuentra.
#
# Salida:
#   0  el bloque coincide exactamente con el patron -> todo bien
#   1  el bloque existe pero DIFIERE del patron -> revisar el diff mostrado
#      (puede ser una edicion manual legitima, o algo inesperado)
#   2  no se encontro el archivo o el bloque marcado -> el script nunca
#      corrio en esta cuenta, o alguien borro el bloque

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFERENCE_FILE="${SCRIPT_DIR}/expected-bashrc-block.sh"
STATE_FILE="/etc/hpc-cluster/node.conf"

MARKER_START="# >>> hpc-cluster-new-nodes-script (bloque generado automaticamente; no borrar) >>>"
MARKER_END="# <<< hpc-cluster-new-nodes-script <<<"

if [[ ! -f "${REFERENCE_FILE}" ]]; then
    echo "No se encontro el patron de referencia: ${REFERENCE_FILE}" >&2
    exit 2
fi

extract_block() {
    # extract_block <archivo> -> imprime SOLO lo que esta entre los
    # marcadores (inclusive). Si hay varios bloques marcados (no deberia
    # pasar; inject_bashrc_block es idempotente) se imprime el primero.
    awk -v start="${MARKER_START}" -v end="${MARKER_END}" '
        $0==start && !done {print; inblock=1; next}
        $0==end && inblock  {print; inblock=0; done=1; next}
        inblock {print}
    ' "$1"
}

user="${1:-}"
if [[ -z "${user}" ]]; then
    if [[ -f "${STATE_FILE}" ]]; then
        user="$(grep '^CLUSTER_USER=' "${STATE_FILE}" | tail -n1 | cut -d= -f2)"
    fi
    user="${user:-ryzen}"
fi

user_home="$(getent passwd "${user}" | cut -d: -f6)"
if [[ -z "${user_home}" ]]; then
    echo "[FALTA] El usuario '${user}' no existe en este sistema."
    exit 2
fi
bashrc_file="${user_home}/.bashrc"

echo "Usuario:  ${user}"
echo "Archivo:  ${bashrc_file}"
echo "Patron:   ${REFERENCE_FILE}"
echo

if [[ ! -f "${bashrc_file}" ]]; then
    echo "[FALTA] No existe ${bashrc_file}."
    exit 2
fi

if ! grep -qF "${MARKER_START}" "${bashrc_file}"; then
    echo "[FALTA] ${bashrc_file} no tiene el bloque de configure-new-node.sh."
    echo "        (¿corriste el script sobre esta cuenta? ¿alguien lo borro?)"
    exit 2
fi

# El prefijo del stack HPC es el unico dato que varia legitimamente de un
# nodo a otro; se toma el valor real guardado por el script (o /usr/local
# por defecto) y se ajusta el patron antes de comparar.
expected_prefix="/usr/local"
if [[ -f "${STATE_FILE}" ]]; then
    saved_prefix="$(grep '^HPC_INSTALL_PREFIX=' "${STATE_FILE}" | tail -n1 | cut -d= -f2)"
    [[ -n "${saved_prefix}" ]] && expected_prefix="${saved_prefix}"
fi

actual_block="$(mktemp)"
expected_block="$(mktemp)"
diff_out="$(mktemp)"
trap 'rm -f "${actual_block}" "${expected_block}" "${diff_out}"' EXIT

extract_block "${bashrc_file}" > "${actual_block}"
sed "s#/usr/local#${expected_prefix}#g" "${REFERENCE_FILE}" > "${expected_block}"

if diff -u --label "esperado" --label "actual (${bashrc_file})" "${expected_block}" "${actual_block}" > "${diff_out}"; then
    echo "[OK] El bloque coincide exactamente con el patron esperado."
    exit 0
else
    echo "[DIFIERE] El bloque en ${bashrc_file} NO coincide con el patron de referencia."
    echo "          Puede ser una edicion manual legitima o algo inesperado (revisa el diff):"
    echo
    cat "${diff_out}"
    exit 1
fi
