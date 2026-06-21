#!/bin/bash
# =============================================================================
# install.bash — Porta de entrada única: baixa (git recursivo) o sistema
# acoplado MONAN-Coupler (com MONAN-Model e MOM6-examples como submódulos) e,
# em seguida, dispara a instalação completa (etapas 1→2→3).
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# Os scripts de instalação vivem em repositório PRÓPRIO (separado do sistema
# acoplado). Fluxo recomendado para o usuário:
#
#   git clone https://github.com/GTA-DIMNT-CPTEC/Coupler-Install.git
#   cd Coupler-Install
#   bash install.bash
#
# USO:
#   bash install.bash [OPÇÕES] [-- ARGS_DO_BUILD]
#
# OPÇÕES:
#   --coupler-root DIR   Onde clonar/encontrar o MONAN-Coupler
#                        (padrão: ./MONAN-Coupler). Também via COUPLER_ROOT.
#   --url URL            Repositório do sistema acoplado
#                        (padrão: GTA-DIMNT-CPTEC/MONAN-Coupler). Via COUPLER_URL.
#   --branch BRANCH      Branch a clonar (padrão: develop). Via COUPLER_BRANCH.
#   --no-install         Apenas baixa o sistema; não compila.
#   --from N | --only N  Repassados ao build.bash (retomar/somente etapa N).
#   --help, -h           Esta mensagem.
#
# EXEMPLOS:
#   bash install.bash                          # baixa (develop) e instala tudo
#   bash install.bash --no-install             # só baixa o sistema
#   bash install.bash --coupler-root /scratch/$USER/MC
#   bash install.bash --branch main --from 2   # outra branch; retoma na etapa 2
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=include.bash
source "${SCRIPT_DIR}/include.bash"

# ── Padrões (sobrescrevíveis por ambiente) ────────────────────────────────────
COUPLER_URL="${COUPLER_URL:-https://github.com/GTA-DIMNT-CPTEC/MONAN-Coupler.git}"
COUPLER_BRANCH="${COUPLER_BRANCH:-develop}"
COUPLER_ROOT="${COUPLER_ROOT:-$(pwd)/MONAN-Coupler}"
DO_INSTALL=true
declare -a INSTALL_ARGS=()

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --coupler-root) COUPLER_ROOT="${2:?--coupler-root exige um diretório}"; shift 2 ;;
    --url)          COUPLER_URL="${2:?--url exige uma URL}";                 shift 2 ;;
    --branch)       COUPLER_BRANCH="${2:?--branch exige um nome}";           shift 2 ;;
    --no-install)   DO_INSTALL=false; shift ;;
    --from|--only)  INSTALL_ARGS+=( "$1" "${2:?$1 exige um número (1-3)}" ); shift 2 ;;
    --help|-h)      usage ;;
    --)             shift; INSTALL_ARGS+=( "$@" ); break ;;
    *) log_error "Opção desconhecida: $1   (use --help)"; exit 1 ;;
  esac
done

# ── Preflight: confere os artefatos locais ANTES do clone demorado ────────────
# Reúne TODOS os problemas de uma vez (evita falhar etapa por etapa). O template
# mkmf só é exigido quando haverá instalação (etapa 2).
preflight_ok=true
if ! resolve_site_env "${SCRIPT_DIR}"; then
  log_error "site-jaci.bash não encontrado junto aos scripts do instalador."
  preflight_ok=false
fi
if [[ "${DO_INSTALL}" == true ]] && ! resolve_mkmf_template "${SCRIPT_DIR}"; then
  log_error "Template mkmf cray-gnu-monan.mk não encontrado junto aos scripts."
  preflight_ok=false
fi
if [[ "${preflight_ok}" != true ]]; then
  log_info "Esperados no diretório do instalador: ${SCRIPT_DIR}"
  log_info "  • site-jaci.bash        (ou exporte SITE_ENV)"
  log_info "  • cray-gnu-monan.mk     (ou templates/…, ou exporte MKMF_TEMPLATE_SRC)"
  log_info "Coloque os arquivos faltantes e rode novamente (o download é idempotente)."
  exit 1
fi
log_ok "Config de sítio: ${SITE_ENV}"
[[ "${DO_INSTALL}" == true ]] && log_ok "Template mkmf: ${MKMF_TEMPLATE_SRC}"

# ── Download recursivo do sistema acoplado ────────────────────────────────────
log_sep
log_info "Instalação completa (download recursivo + build) — MONAN-A 2.0 × MOM6+SIS2"
log_info "INPE / CGCT / DIMNT — GT Acoplamento de Modelos"
log_sep

timer_start
clone_recursive_if_missing "${COUPLER_ROOT}" "${COUPLER_URL}" "${COUPLER_BRANCH}"

# Normaliza para caminho absoluto e disponibiliza às etapas seguintes.
COUPLER_ROOT="$(cd "${COUPLER_ROOT}" && pwd)"
export COUPLER_ROOT

# Config de sítio já resolvida acima (SITE_ENV exportado). Deixa uma cópia em
# <COUPLER_ROOT>/run/setenv-site.bash para que futuras sessões de build do
# usuário ('source run/setenv-gnu.bash') a encontrem sem o instalador presente.
# (Assim não é preciso manter um diretório install/ na árvore do acoplador.)
cp -f "${SITE_ENV}" "${COUPLER_ROOT}/run/setenv-site.bash"
log_ok "Config de sítio copiada para ${COUPLER_ROOT}/run/setenv-site.bash"

# ── Instalação ────────────────────────────────────────────────────────────────
if [[ "${DO_INSTALL}" == true ]]; then
  log_info "Iniciando instalação (COUPLER_ROOT=${COUPLER_ROOT})"
  bash "${SCRIPT_DIR}/build.bash" "${INSTALL_ARGS[@]}"
else
  log_sep
  timer_total "Download concluído em"
  echo ""
  log_ok  "Sistema em: ${COUPLER_ROOT}"
  log_info "Para instalar depois:  COUPLER_ROOT='${COUPLER_ROOT}' bash build.bash"
  log_sep
fi
