#!/bin/bash
# =============================================================================
# 3-install-coupler.bash — Compila e linka o acoplador no executável final
# bin/esmApp (NUOPC/ESMF 8.9.1). 3ª e última etapa de instalação.
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# Pré-requisitos (etapas 1 e 2):
#   lib/monan2/            (1-install-monan.bash)
#   lib/{fms,mom6,nuopc}/  (2-install-mom.bash)
#
# USO:
#   bash 3-install-coupler.bash [--no-clean] [--help]
#     --no-clean   Pula 'make clean' (recompilação incremental).
#
# ATENÇÃO: usa 'make clean' (apaga build/ e bin/), nunca 'make distclean'
# (que removeria lib/ e mod/ instalados pelas etapas 1 e 2).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=include.bash
source "${SCRIPT_DIR}/include.bash"
# Scripts em repositório próprio: COUPLER_ROOT vem do ambiente/install.bash.
resolve_coupler_root

# ── Opções ────────────────────────────────────────────────────────────────────
NO_CLEAN=false

usage() {
  cat << 'EOF'
Uso: bash 3-install-coupler.bash [--no-clean] [--help]

  Compila e linka o acoplador no executável final bin/esmApp
  (3ª e última etapa). Requer lib/monan2 (etapa 1) e lib/{fms,mom6,nuopc}
  (etapa 2).

Opções:
  --no-clean   Pula 'make clean' (recompilação incremental).
  --help, -h   Esta mensagem.

ATENÇÃO: usa 'make clean' (apaga build/ e bin/), nunca 'make distclean'
(que removeria lib/ e mod/ instalados pelas etapas 1 e 2).
EOF
  exit 0
}

for _arg in "$@"; do
  case "${_arg}" in
    --no-clean) NO_CLEAN=true ;;
    --help|-h)  usage ;;
    *) log_error "Opção desconhecida: ${_arg}   (use --help)"; exit 1 ;;
  esac
done
unset _arg

# ── Ambiente de build (ESMF, MPAS, MOM6) ──────────────────────────────────────
# A config de sítio vive no repositório do instalador. Localiza-a (mesma lógica
# das etapas 1-2) e exporta SITE_ENV para que o run/setenv-gnu.bash do acoplador
# use a configuração correta (em vez do fallback interno à árvore do acoplador).
if ! resolve_site_env "${SCRIPT_DIR}"; then
  log_error "site-jaci.bash não encontrado (coloque-o junto aos scripts ou exporte SITE_ENV)."
  exit 1
fi
log_info "Config de sítio: ${SITE_ENV}"

SETENV="${COUPLER_ROOT}/run/setenv-gnu.bash"
if [[ ! -f "${SETENV}" ]]; then
  log_error "Arquivo de ambiente não encontrado: ${SETENV}"
  exit 1
fi
# shellcheck source=/dev/null
source "${SETENV}"

if ! check_var ESMFMKFILE MPAS_DIR; then
  log_error "Ambiente incompleto após source de ${SETENV}"
  exit 1
fi

# ── Compilação ────────────────────────────────────────────────────────────────
cd "${COUPLER_ROOT}"
timer_start

if [[ "${NO_CLEAN}" == false ]]; then
  log_step 1 2 "Limpeza (make clean)"
  log_warn "build/ e bin/ serão removidos. Use --no-clean para pular."
  make clean
  log_ok "Limpeza concluída."
else
  log_warn "Limpeza ignorada (--no-clean). Build incremental."
fi

log_step 2 2 "Compilação do acoplador (make all)"
make all 2>&1 | tee make-coupler.log

# ── Verificação e resumo ──────────────────────────────────────────────────────
log_sep
echo ""
if [[ -f "${COUPLER_ROOT}/bin/esmApp" ]]; then
  timer_total "Acoplador compilado em"
  echo ""
  _info=$(stat -c '%s bytes, %y' "${COUPLER_ROOT}/bin/esmApp" | cut -d. -f1)
  log_ok "bin/esmApp  [${_info}]"
  echo ""
  log_info "Próximo passo: bash run/run_esmApp.jaci -n 128"
else
  log_error "bin/esmApp não foi gerado — verifique make-coupler.log"
  exit 1
fi
log_sep
