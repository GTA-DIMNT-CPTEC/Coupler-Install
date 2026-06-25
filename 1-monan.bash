#!/bin/bash
# =============================================================================
# 1-install-monan.bash — Compila o MONAN-A 2.0 (MPAS-A 8.3.1) na Jaci e
# consolida módulos (.mod) e bibliotecas (.a) em diretórios únicos usados pelo
# Makefile do acoplador (variáveis MONAN2_MODDIR / MONAN2_LIBDIR).
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# USO (a partir de qualquer diretório):
#   bash 1-install-monan.bash [OPÇÕES]
#
# OPÇÕES:
#   --skip-init-atm   Compila apenas o core 'atmosphere'; pula 'init_atmosphere'
#                     (útil em hosts que não precisam gerar condições iniciais).
#   --help            Exibe esta mensagem de ajuda e encerra.
#
# O script se ancora no próprio diretório (BASH_SOURCE), portanto independe
# do diretório de invocação.
#
# LAYOUT RESULTANTE (na raiz do MONAN-Coupler; a árvore de fontes do MONAN-A
# fica em models/atmos/MONAN-Model):
#   <raiz>/mod/monan2            módulos do core 'atmosphere'
#   <raiz>/lib/monan2            bibliotecas do core 'atmosphere'
#   <raiz>/mod/init_atmosphere   módulos do core 'init_atmosphere'  (opcional)
#   <raiz>/lib/init_atmosphere   bibliotecas do core 'init_atmosphere' (opcional)
#
# NOTAS DE PROJETO
#   1. Os artefatos de 'init_atmosphere' ficam em diretórios SEPARADOS: ambos os
#      cores geram libdycore.a (mesmo nome) e há .mod homônimos; misturá-los em
#      mod/monan2 e lib/monan2 sobrescreveria o dycore do 'atmosphere' — que é
#      justamente o que o acoplador linka.
#   2. AUTOCLEAN=true faz o MPAS limpar o core anterior ao trocar CORE=. Por
#      isso a cópia do core 'atmosphere' ocorre ANTES de compilar
#      'init_atmosphere'; caso contrário os artefatos seriam apagados.
#   3. Se o diretório MONAN-Model não existir, o script o baixa automaticamente
#      de https://github.com/GTA-DIMNT-CPTEC/MONAN-Model e faz checkout do commit
#      fixado (01962f03). Sobrescreva a origem e a revisão com as variáveis de
#      ambiente MONAN_MODEL_URL e MONAN_MODEL_REF.
# =============================================================================
set -euo pipefail

# ── Âncora determinística ─────────────────────────────────────────────────────
# Os scripts de instalação ficam em repositório próprio, fora do acoplador.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Carrega biblioteca de funções ─────────────────────────────────────────────
# shellcheck source=include.bash
source "${SCRIPT_DIR}/include.bash"

# ── Raiz do acoplador (ambiente/install.bash; valida e exporta COUPLER_ROOT) ─────
resolve_coupler_root

# ── Carrega a configuração de sítio (ESMF, módulos, paralelismo, alvos) ───────
load_site_env "${SCRIPT_DIR}"

# ── Análise de opções ─────────────────────────────────────────────────────────
SKIP_INIT_ATM=false

usage() {
  cat << 'EOF'
Uso: bash 1-install-monan.bash [OPÇÕES]

  Compila o MONAN-A 2.0 (MPAS-A 8.3.1) e consolida módulos (.mod) e
  bibliotecas (.a) em mod/monan2 e lib/monan2 para o Makefile do acoplador.

Opções:
  --skip-init-atm   Compila apenas o core 'atmosphere' (pula 'init_atmosphere').
  --help, -h        Esta mensagem.
EOF
  exit 0
}

for _arg in "$@"; do
  case "${_arg}" in
    --skip-init-atm)  SKIP_INIT_ATM=true  ;;
    --help|-h)        usage ;;
    *)
      log_error "Opção desconhecida: ${_arg}   (use --help para a lista de opções)"
      exit 1
      ;;
  esac
done
unset _arg

# ── Definição de caminhos ─────────────────────────────────────────────────────
# A árvore de fontes do MONAN-A 2.0 vive em models/atmos/ (layout multi-modelo
# do MONAN-Coupler). Os artefatos consolidados (mod/, lib/) permanecem na raiz.
MONAN_MODEL="${COUPLER_ROOT}/models/atmos/MONAN-Model"

MOD_ATM="${COUPLER_ROOT}/mod/monan2"
LIB_ATM="${COUPLER_ROOT}/lib/monan2"
MOD_INIT="${COUPLER_ROOT}/mod/init_atmosphere"
LIB_INIT="${COUPLER_ROOT}/lib/init_atmosphere"

# ── Pré-condição: árvore de fontes ────────────────────────────────────────────
# Normalmente o MONAN-Model já chega como submódulo no clone recursivo do
# sistema (install.bash). ensure_model_tree confirma a presença e, se faltar,
# inicializa o submódulo; sem submódulo, faz clone direto (legado). Origem e
# revisão sobrescrevíveis por ambiente:
#   export MONAN_MODEL_URL=https://github.com/MEU_USUARIO/MONAN-Model.git
#   export MONAN_MODEL_REF=<commit|tag|branch>
MONAN_MODEL_URL="${MONAN_MODEL_URL:-https://github.com/GTA-DIMNT-CPTEC/MONAN-Model.git}"
MONAN_MODEL_REF="${MONAN_MODEL_REF:-01962f03d796d63e355fccf7e36010173570c31e}"
ensure_model_tree "${MONAN_MODEL}" "${COUPLER_ROOT}" "models/atmos/MONAN-Model" \
                  "${MONAN_MODEL_URL}" "${MONAN_MODEL_REF}"

# ── Módulos Jaci (Cray XD 2000 com PrgEnv-gnu) ────────────────────────────────
log_sep
log_info "Carregando módulos do ambiente Jaci..."
load_modules "${MODULES_MONAN[@]}"

# PNETCDF_DIR é injetado pelo módulo cray-parallel-netcdf
if [[ -z "${PNETCDF_DIR:-}" ]]; then
  log_error "PNETCDF_DIR não definido — módulo 'cray-parallel-netcdf' carregou?"
  exit 1
fi
export PNETCDF="${PNETCDF_DIR}"

# NETCDF_DIR é injetado pelo módulo cray-netcdf (NetCDF serial). O link do MPAS
# referencia -lnetcdf -lnetcdff em utilitários (ex.: build_tables) e no
# executável; sem este caminho ocorre "ld: cannot find -lnetcdf".
if [[ -z "${NETCDF_DIR:-}" ]]; then
  log_error "NETCDF_DIR não definido — módulo 'cray-netcdf' carregou?"
  exit 1
fi
export NETCDF="${NETCDF_DIR}"

# ── ESMF 8.9.1 externo (acoplador) ────────────────────────────────────────────
# ESMF_MOD (dir do esmf.mod) e ESMF_LIBDIR (dir da libesmf.a) são derivados do
# esmf.mk na config de sítio (sites/site-jaci.bash) — fonte única. O alvo
# gfortran-coupler-xd2000 compila com -DMPAS_EXTERNAL_ESMF_LIB e o Makefile do
# MONAN-Model injeta -I$(ESMF_MOD) (à frente do stub src/external/esmf_time_f90)
# e -L$(ESMF_LIBDIR) -lesmf a partir delas. Sem essas variáveis o 'use ESMF'
# cairia no stub e a compilação falharia em timeStringISOFrac (ESMF_TimeGet) e
# no keyword h= (ESMF_TimeIntervalGet). Aqui apenas conferimos a presença.
if ! check_var ESMF_MOD ESMF_LIBDIR; then
  log_error "ESMF_MOD/ESMF_LIBDIR ausentes — a config de sítio derivou o ESMF?"
  log_info  "Confira ESMFMKFILE em ${SITE_ENV} e a instalação do ESMF 8.9.1."
  log_info  "(Sítio antigo? Atualize sites/site-jaci.bash com a derivação do ESMF.)"
  exit 1
fi
log_ok "ESMF externo  ESMF_MOD=${ESMF_MOD}"
log_ok "ESMF externo  ESMF_LIBDIR=${ESMF_LIBDIR}"

cd "${MONAN_MODEL}"

# Flags de compilação — comuns aos dois cores (array: expansão segura, sem
# depender de word-splitting de uma string).
MAKE_ARGS=(OPENMP=true USE_PIO2=false PRECISION=double AUTOCLEAN=true)

# ── ETAPA 1 — Core 'atmosphere' (compilação e cópia dos artefatos) ────────────
# A cópia DEVE ocorrer ANTES da compilação do 'init_atmosphere': com
# AUTOCLEAN=true, a troca de CORE= apaga os artefatos do core anterior.
log_step 1 2 "Core 'atmosphere' — compilação"
timer_start

make -j "${MAKE_JOBS}" "${MONAN_TARGET}" CORE=atmosphere "${MAKE_ARGS[@]}" 2>&1 \
  | tee make-atmosphere.log

timer_step "Core 'atmosphere' compilado"

log_step 1 2 "Core 'atmosphere' — cópia dos artefatos para ${MOD_ATM} / ${LIB_ATM}"

mkdir -p "${MOD_ATM}" "${LIB_ATM}"

# Módulos (.mod) → mod/monan2
cp_glob "./src/core_atmosphere/*.mod"                                     "${MOD_ATM}"
cp_glob "./src/core_atmosphere/diagnostics/*.mod"                         "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/*.mod"                             "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/physics_noahmp/drivers/mpas/*.mod" "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/physics_noahmp/utility/*.mod"      "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/physics_noahmp/src/*.mod"          "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/physics_mmm/*.mod"                 "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/physics_wrf/*.mod"                 "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/physics_noaa/UGWP/*.mod"           "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/physics_monan/*.mod"               "${MOD_ATM}"
cp_glob "./src/core_atmosphere/utils/*.mod"                               "${MOD_ATM}"
cp_glob "./src/core_atmosphere/dynamics/*.mod"                            "${MOD_ATM}"
cp_glob "./src/driver/*.mod"                                              "${MOD_ATM}"
cp_glob "./src/external/esmf_time_f90/*.mod"                              "${MOD_ATM}"
cp_glob "./src/external/SMIOL/*.mod"                                      "${MOD_ATM}"
cp_glob "./src/framework/*.mod"                                           "${MOD_ATM}"
cp_glob "./src/operators/*.mod"                                           "${MOD_ATM}"

# Bibliotecas (.a) → lib/monan2
cp_glob "./src/operators/*.a"                   "${LIB_ATM}"
cp_glob "./src/core_atmosphere/*.a"             "${LIB_ATM}"
cp_glob "./src/core_atmosphere/physics/*.a"     "${LIB_ATM}"
cp_glob "./src/external/esmf_time_f90/*.a"      "${LIB_ATM}"
cp_glob "./src/external/SMIOL/*.a"              "${LIB_ATM}"
cp_glob "./src/framework/*.a"                   "${LIB_ATM}"

log_ok "Artefatos do 'atmosphere' copiados."

# ── ETAPA 2 — Core 'init_atmosphere' (gerador de condições iniciais) ──────────
# Pule com --skip-init-atm se não precisar gerar condições iniciais neste host.
if [[ "${SKIP_INIT_ATM}" == false ]]; then
  log_step 2 2 "Core 'init_atmosphere' — compilação"

  make -j "${MAKE_JOBS}" "${MONAN_TARGET}" CORE=init_atmosphere "${MAKE_ARGS[@]}" 2>&1 \
    | tee make-init_atmosphere.log

  timer_step "Core 'init_atmosphere' compilado"

  mkdir -p "${MOD_INIT}" "${LIB_INIT}"
  cp_glob "./src/core_init_atmosphere/*.mod" "${MOD_INIT}"
  cp_glob "./src/core_init_atmosphere/*.a"   "${LIB_INIT}"
  log_ok "Artefatos do 'init_atmosphere' copiados."
else
  log_warn "init_atmosphere ignorado (--skip-init-atm)."
fi

# ── Verificação: 6 bibliotecas exigidas pelo Makefile do acoplador ────────────
log_sep
echo ""
log_info "Verificação: 6 bibliotecas do core 'atmosphere' em lib/monan2"
echo ""

_miss=0
for _lib in "${MONAN2_LIBS[@]}"; do
  if [[ -f "${LIB_ATM}/${_lib}" ]]; then
    log_ok "${_lib}"
  else
    log_warn "${_lib}  <-- AUSENTE"
    _miss=$(( _miss + 1 ))
  fi
done
echo ""

if [[ ${_miss} -eq 0 ]]; then
  timer_total "Instalação do MONAN-A concluída em"
  echo ""
  log_ok "Módulos  : ${MOD_ATM}"
  log_ok "Libs     : ${LIB_ATM}"
  echo ""
  log_info "Próximo passo: bash 2-install-mom.bash"
else
  log_error "${_miss} biblioteca(s) ausente(s) — verifique make-atmosphere.log"
  exit 1
fi
