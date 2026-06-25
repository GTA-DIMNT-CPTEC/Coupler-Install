#!/bin/bash
# =============================================================================
# 2-install-mom.bash — Compila MOM6+SIS2 (+ FMS) com mkmf no Cray/GNU e gera
# a biblioteca do cap NUOPC (libmom6_nuopc.a) usada pelo acoplador.
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# USO (a partir de qualquer diretório):
#   bash 2-install-mom.bash [OPÇÕES]
#
# OPÇÕES:
#   --only-nuopc   Pula FMS e MOM6 standalone; compila apenas o cap NUOPC.
#                  Use quando FMS e MOM6 já foram compilados anteriormente.
#   --help         Exibe esta mensagem de ajuda e encerra.
#
# DOWNLOAD AUTOMÁTICO: se a árvore MOM6-examples não existir (ou estiver vazia),
# o script a baixa de https://github.com/GTA-DIMNT-CPTEC/MOM6-examples (com
# submódulos) e faz checkout do commit fixado (cec94e47). Sobrescreva a origem e
# a revisão com as variáveis de ambiente MOM6_EXAMPLES_URL e MOM6_EXAMPLES_REF.
#
# ARTEFATOS GERADOS (sob MOM6-examples/build/gnu/):
#   shared/repro/libfms.a              infraestrutura FMS
#   ice_ocean_SIS2/repro/MOM6          executável standalone (validação)
#   nuopc_cap/repro/libmom6_nuopc.a    cap NUOPC para o acoplador
#
# Copiados para <raiz>/lib/{fms,mom6,nuopc}/ e mod/{fms,mom6,nuopc}/.
#
# NOTA: Os objetos .o de ice_ocean_SIS2 são copiados para lib/mom6/ e linkados
# diretamente pelo Makefile do acoplador (via MOM6_OBJS). Isso evita problemas
# de símbolos duplicados com a libmom6_nuopc.a.
#
# NOTA CRAY: o compilador é sempre o wrapper 'ftn' (nunca gfortran direto).
# =============================================================================
set -euo pipefail

# --- Âncora determinística ---------------------------------------------------
# Os scripts de instalação ficam em repositório próprio, fora do acoplador.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Carrega biblioteca de funções -------------------------------------------
# shellcheck source=include.bash
source "${SCRIPT_DIR}/include.bash"

# --- Raiz do acoplador (ambiente/install.bash; valida e exporta COUPLER_ROOT) ----
resolve_coupler_root

# --- Carrega a configuração de sítio (ESMF, módulos, paralelismo, wrappers) ---
load_site_env "${SCRIPT_DIR}"

# =============================================================================
# Análise de opções
# =============================================================================
ONLY_NUOPC=false

usage() {
  cat << 'EOF'
Uso: bash 2-install-mom.bash [OPÇÕES]

  Compila MOM6+SIS2 (+ FMS) com mkmf no Cray/GNU e gera a biblioteca do
  cap NUOPC (libmom6_nuopc.a) usada pelo acoplador.

Opções:
  --only-nuopc   Pula FMS e MOM6 standalone; compila só o cap NUOPC
                 (use quando FMS e MOM6 já foram compilados antes).
  --help, -h     Esta mensagem.
EOF
  exit 0
}

for _arg in "$@"; do
  case "${_arg}" in
    --only-nuopc)   ONLY_NUOPC=true  ;;
    --help|-h)      usage ;;
    *)
      log_error "Opção desconhecida: ${_arg}   (use --help para a lista de opções)"
      exit 1
      ;;
  esac
done
unset _arg

# =============================================================================
# Caminhos (maiúsculas por convenção de variáveis de ambiente)
# =============================================================================
# A árvore de fontes do MOM6+SIS2 vive em models/ocean/ (layout multi-modelo
# do MONAN-Coupler). Os artefatos instalados (lib/, mod/) permanecem na raiz.
MOM6_EXAMPLES_DIR="${COUPLER_ROOT}/models/ocean/MOM6-examples"

# Normalmente o MOM6-examples já chega como submódulo no clone recursivo do
# sistema (install.bash), inclusive seus submódulos aninhados. ensure_model_tree
# confirma a presença e, se faltar, inicializa o submódulo recursivamente; sem
# submódulo, faz clone direto --recursive (legado). Sobrescrevíveis por ambiente:
#   export MOM6_EXAMPLES_URL=https://github.com/MEU_USUARIO/MOM6-examples.git
#   export MOM6_EXAMPLES_REF=<commit|tag|branch>
MOM6_EXAMPLES_URL="${MOM6_EXAMPLES_URL:-https://github.com/GTA-DIMNT-CPTEC/MOM6-examples.git}"
MOM6_EXAMPLES_REF="${MOM6_EXAMPLES_REF:-cec94e473bfee1bc3ee9b3c64e147361123fd7fb}"
ensure_model_tree "${MOM6_EXAMPLES_DIR}" "${COUPLER_ROOT}" "models/ocean/MOM6-examples" \
                  "${MOM6_EXAMPLES_URL}" "${MOM6_EXAMPLES_REF}"

# =============================================================================
# SEÇÃO DE CONFIGURAÇÃO — revise ao migrar de usuário ou máquina
# =============================================================================

# Módulos Cray XD 2000 (definidos em site-jaci.bash → MODULES_MOM6).
# MOM6/FMS usam NetCDF/HDF5 seriais (cray-netcdf), não o parallel-netcdf do
# MPAS; o wrapper 'ftn' injeta includes e libs quando o módulo está carregado.
load_modules "${MODULES_MOM6[@]}"

# ESMF — esmf.mk definido em site-jaci.bash (ESMFMKFILE), sobrescrevível por
# ambiente. É o único ponto de configuração do ESMF.
if [[ ! -f "${ESMFMKFILE}" ]]; then
  log_error "esmf.mk não encontrado: ${ESMFMKFILE}"
  log_info  "Ajuste ESMF_ROOT/ESMFMKFILE em site-jaci.bash ou exporte ESMFMKFILE."
  exit 1
fi

# Extrai uma variável (já expandida) do esmf.mk, deixando o make resolver
# referências internas. Usado no Passo 3 (flags canônicas do cap NUOPC).
# Uso: _esmf_mk ESMF_F90COMPILEPATHS
_esmf_mk() {
  printf 'include %s\n_v:\n\t@echo $(%s)\n' "${ESMFMKFILE}" "$1" | make -s -f - _v 2>/dev/null
}

# Bibliotecas do ESMF em runtime (LD_LIBRARY_PATH). ESMF_LIBDIR é derivado de
# forma robusta pela config de sítio (sites/site-jaci.bash) — fonte única — e
# não pela variável ESMF_LIBDIR do esmf.mk, que não existe em todo build do
# ESMF. Aqui apenas o consumimos. O sufixo ${VAR:+:${VAR}} evita ':' inicial/
# final (que poria '.' no caminho).
if ! check_var ESMF_LIBDIR; then
  log_error "ESMF_LIBDIR ausente — a config de sítio derivou o ESMF?"
  log_info  "Confira ESMFMKFILE em ${SITE_ENV} e a instalação do ESMF 8.9.1."
  log_info  "(Sítio antigo? Atualize sites/site-jaci.bash com a derivação do ESMF.)"
  exit 1
fi
export LD_LIBRARY_PATH="${ESMF_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# Apps do ESMF (ESMF_RegridWeightGen etc.): úteis em runtime/pós-proc, não na
# compilação. ESMF_APPSDIR nem sempre é exposto pelo esmf.mk; se vier vazio,
# apenas não o adicionamos ao PATH (não é fatal para o build).
_esmf_appsdir="$(_esmf_mk ESMF_APPSDIR)"
if [[ -n "${_esmf_appsdir}" ]]; then
  export PATH="${_esmf_appsdir}${PATH:+:${PATH}}"
else
  log_warn "ESMF_APPSDIR não exposto pelo esmf.mk — apps do ESMF fora do PATH (ok para compilar)."
fi
unset _esmf_appsdir
log_ok "ESMF via ${ESMFMKFILE}  (LIBDIR=${ESMF_LIBDIR})"

# Wrappers Cray (valores definidos em site-jaci.bash; nunca gfortran/gcc direto).
export FC CC LD

# Habilita a compilação do MOM6 com gelo marinho SIS2 (recomendado).
# Mude para false para compilar apenas oceano sem gelo (ocean_only).
BUILD_SIS2=true

# =============================================================================
# FIM DA SEÇÃO DE CONFIGURAÇÃO
# =============================================================================

# Utilitários mkmf (incluídos no repositório MOM6-examples)
MKMF="${MOM6_EXAMPLES_DIR}/src/mkmf/bin/mkmf"
LIST_PATHS="${MOM6_EXAMPLES_DIR}/src/mkmf/bin/list_paths"

# Template mkmf do projeto: versão Cray/GNU já sem os caminhos do NetCDF custom
# (-I/-L .../lib_gnucray/netcdf). Com cray-netcdf carregado, o 'ftn' fornece o
# NetCDF; um caminho custom duplicaria headers e arriscaria divergência de versão.
# Procurado em vários locais (templates/, raiz do instalador, install/…); para
# forçar a origem: export MKMF_TEMPLATE_SRC=/caminho/para/template.mk
if ! resolve_mkmf_template "${SCRIPT_DIR}"; then
  log_error "Template mkmf (cray-gnu-monan.mk) não encontrado."
  log_info  "Locais procurados:"
  log_info  "    • \$MKMF_TEMPLATE_SRC ... ${MKMF_TEMPLATE_SRC:-<não definido>}"
  log_info  "    • ${SCRIPT_DIR}/templates/cray-gnu-monan.mk"
  log_info  "    • ${SCRIPT_DIR}/cray-gnu-monan.mk"
  log_info  "    • ${SCRIPT_DIR}/install/templates/cray-gnu-monan.mk"
  [[ -n "${COUPLER_ROOT:-}" ]] && \
  log_info  "    • ${COUPLER_ROOT}/install/templates/cray-gnu-monan.mk"
  log_info  "Coloque o template junto aos scripts ou exporte MKMF_TEMPLATE_SRC."
  exit 1
fi
TEMPLATE_MK="${MKMF_TEMPLATE_SRC}"

# Verifica as demais ferramentas de build necessárias (mkmf, list_paths).
for _tool in "${MKMF}" "${LIST_PATHS}"; do
  if [[ ! -e "${_tool}" ]]; then
    log_error "Ferramenta de build não encontrada: ${_tool}"
    exit 1
  fi
done
unset _tool

# Guarda de segurança: o template não pode reintroduzir o NetCDF custom.
if grep -q 'lib_gnucray/netcdf' "${TEMPLATE_MK}"; then
  log_error "Template contém referência ao NetCDF custom (lib_gnucray/netcdf): ${TEMPLATE_MK}"
  log_info  "Remova os caminhos -I/-L .../lib_gnucray/netcdf do template."
  exit 1
fi
log_ok "Template mkmf: ${TEMPLATE_MK}"

timer_start

# =============================================================================
# PASSO 1/3 — FMS (infraestrutura base; deve ser compilada antes de tudo)
# =============================================================================
if [[ "${ONLY_NUOPC}" == false ]]; then
  log_step 1 3 "FMS — infraestrutura base"

  rm -rf "${MOM6_EXAMPLES_DIR}/build"
  mkdir -p "${MOM6_EXAMPLES_DIR}/build/gnu/shared/repro"
  cd "${MOM6_EXAMPLES_DIR}/build/gnu/shared/repro"

  rm -f path_names
  # Usar src/FMS2 (FMS 2022.02, com fms2_io), e NÃO src/FMS (= FMS1 2019.01.03,
  # que só tem mpp_io). O MOM6 deste repositório usa config_src/infra/FMS2 nos
  # Passos 2 e 3, logo a libfms.a precisa fornecer fms2_io_mod/fms_io_utils_mod.
  ${LIST_PATHS} -l ../../../../src/FMS2
  ${MKMF} \
      -t "${TEMPLATE_MK}" \
      -p libfms.a \
      -c "-Duse_libMPI -Duse_netCDF -DSPMD" \
      path_names

  # NETCDF=4: o fms2_io exige a API NetCDF-4/HDF5 (fornecida por cray-netcdf).
  make NETCDF=4 REPRO=1 libfms.a -j "${MAKE_JOBS}" 2>&1 | tee make_fms.log

  timer_step "[1/3] FMS compilado"
else
  log_warn "Passo 1/3 (FMS) ignorado (--only-nuopc)."
fi

cd "${MOM6_EXAMPLES_DIR}"

# =============================================================================
# PASSO 2/3 — MOM6 standalone (validação de compilação antes do cap NUOPC)
# =============================================================================
if [[ "${ONLY_NUOPC}" == false ]]; then
  if [[ "${BUILD_SIS2}" == true ]]; then
    _mom6_target="ice_ocean_SIS2"
    log_step 2 3 "MOM6 + SIS2 standalone (ice_ocean_SIS2)"

    mkdir -p "${MOM6_EXAMPLES_DIR}/build/gnu/ice_ocean_SIS2/repro"
    cd "${MOM6_EXAMPLES_DIR}/build/gnu/ice_ocean_SIS2/repro"

    rm -f path_names
    ${LIST_PATHS} -l              \
         ./ \
        ../../../../src/MOM6/config_src/{infra/FMS2,memory/dynamic_symmetric,drivers/FMS_cap,external} \
        ../../../../src/SIS2/config_src/dynamic_symmetric             \
        ../../../../src/MOM6/src/{*,*/*}/                             \
        ../../../../src/atmos_null                                    \
        ../../../../src/land_null                                     \
        ../../../../src/coupler                                       \
        ../../../../src/{ice_param,icebergs/src,SIS2,FMS/coupler,FMS/include}
    ${MKMF} \
        -t "${TEMPLATE_MK}" \
        -o "-I../../shared/repro  -I../../ice_ocean_SIS2/repro" \
        -p MOM6 \
        -l "-L../../shared/repro -lfms" \
        -c "-Duse_libMPI -Duse_netCDF -DSPMD -Duse_AM3_physics -D_USE_LEGACY_LAND_" \
        path_names

    make REPRO=1 MOM6 -j "${MAKE_JOBS}" 2>&1 | tee make_mom6_ice_ocean_SIS2.log
  else
    _mom6_target="ocean_only"
    log_step 2 3 "MOM6 standalone (ocean_only — sem gelo)"

    mkdir -p "${MOM6_EXAMPLES_DIR}/build/gnu/ocean_only/repro"
    cd "${MOM6_EXAMPLES_DIR}/build/gnu/ocean_only/repro"

    rm -f path_names
    ${LIST_PATHS} -l \
        ../../../../src/MOM6/config_src/infra/FMS2 \
        ../../../../src/MOM6/config_src/memory/dynamic_symmetric \
        ../../../../src/MOM6/config_src/drivers/solo_driver \
        ../../../../src/MOM6/config_src/external \
        ../../../../src/MOM6/src/{*,*/*}
    ${MKMF} \
        -t "${TEMPLATE_MK}" \
        -o "-I../../shared/repro" \
        -p MOM6 \
        -l "-L../../shared/repro -lfms" \
        -c "-Duse_libMPI -Duse_netCDF -DSPMD" \
        path_names

    make REPRO=1 MOM6 -j "${MAKE_JOBS}" 2>&1 | tee make_mom6_ocean_only.log
  fi

  timer_step "[2/3] MOM6 standalone compilado (${_mom6_target})"
else
  log_warn "Passo 2/3 (MOM6 standalone) ignorado (--only-nuopc)."
  _mom6_target="ice_ocean_SIS2"   # assume para a verificação abaixo
fi

cd "${MOM6_EXAMPLES_DIR}"

# =============================================================================
# PASSO 3/3 — Cap NUOPC (acoplamento MOM6 + MPAS) — etapa principal
# =============================================================================
log_step 3 3 "Cap NUOPC (libmom6_nuopc.a)"

ESMF_COMPILEPATHS="$(_esmf_mk ESMF_F90COMPILEPATHS)"
ESMF_LINKLINE="$(_esmf_mk ESMF_F90LINKPATHS) $(_esmf_mk ESMF_F90LINKRPATHS) $(_esmf_mk ESMF_F90ESMFLINKLIBS)"

if [[ -z "${ESMF_COMPILEPATHS}" || -z "${ESMF_LINKLINE// /}" ]]; then
  log_error "Falha ao extrair flags do esmf.mk: ${ESMFMKFILE}"
  exit 1
fi

mkdir -p "${MOM6_EXAMPLES_DIR}/build/gnu/nuopc_cap/repro"
cd "${MOM6_EXAMPLES_DIR}/build/gnu/nuopc_cap/repro"

rm -f path_names
# Caminhos relativos a ${MOM6_EXAMPLES_DIR}/build/gnu/nuopc_cap/repro:
#   • src/MOM6/...  → DENTRO da árvore do MOM6-examples (4× '../'): inalterados,
#     pois descem junto com o MOM6-examples.
#   • caps/...      → FORA da árvore do MOM6-examples, na raiz do MONAN-Coupler.
#     Com o MOM6-examples agora em models/ocean/, este 'repro' está 2 níveis mais
#     fundo; por isso são 9× '../' (antes 7×) para alcançar a raiz do acoplador.
${LIST_PATHS} -l \
    ../../../../src/MOM6/config_src/infra/FMS2 \
    ../../../../src/MOM6/config_src/memory/dynamic_symmetric \
    ../../../../src/MOM6/config_src/external \
    ../../../../../../../../../caps/atmos/mpas_cap_config.F90 \
    ../../../../../../../../../caps/ocean/*.F90               \
    ../../../../src/MOM6/src/{*,*/*}
${MKMF} \
    -t "${TEMPLATE_MK}" \
    -o "-I../../shared/repro ${ESMF_COMPILEPATHS} -I${MOM6_EXAMPLES_DIR}/src/MOM6/src/framework" \
    -p libmom6_nuopc.a \
    -l "-L../../shared/repro -lfms ${ESMF_LINKLINE}" \
    -c "-Duse_libMPI -Duse_netCDF -DSPMD -DUSE_ESMF_NUOPC -fcheck=all" \
    path_names

make REPRO=1 libmom6_nuopc.a -j "${MAKE_JOBS}" 2>&1 | tee make_mom6_nuopc.log

timer_step "[3/3] Cap NUOPC compilado"

cd "${MOM6_EXAMPLES_DIR}"

# =============================================================================
# Verificação dos artefatos antes de instalar
# =============================================================================
log_sep
log_info "Verificando artefatos gerados..."
echo ""

_miss=0
_artefatos=(
  "build/gnu/shared/repro/libfms.a"
  "build/gnu/${_mom6_target}/repro/MOM6"
  "build/gnu/nuopc_cap/repro/libmom6_nuopc.a"
)

for _f in "${_artefatos[@]}"; do
  if [[ -s "${MOM6_EXAMPLES_DIR}/${_f}" ]]; then
    log_ok "${_f}"
  else
    log_warn "${_f}  <-- AUSENTE ou VAZIO"
    _miss=$(( _miss + 1 ))
  fi
done
unset _artefatos

if [[ ${_miss} -ne 0 ]]; then
  log_error "${_miss} artefato(s) ausente(s) — verifique make_*.log"
  exit 1
fi

# =============================================================================
# Instalação — copia libs e módulos para a árvore do acoplador
# =============================================================================
log_info "Instalando artefatos em ${COUPLER_ROOT}/{lib,mod}/{fms,mom6,nuopc}/..."
echo ""

mkdir -p "${COUPLER_ROOT}"/lib/{fms,mom6,nuopc}
mkdir -p "${COUPLER_ROOT}"/mod/{fms,mom6,nuopc}

# Biblioteca do cap NUOPC e seus módulos
cp_glob "build/gnu/nuopc_cap/repro/*.a"     "${COUPLER_ROOT}/lib/nuopc/"
cp_glob "build/gnu/nuopc_cap/repro/*.mod"   "${COUPLER_ROOT}/mod/nuopc/"

# Objetos do MOM6 standalone: linkados diretamente pelo acoplador (MOM6_OBJS
# no Makefile). Os .o ficam em lib/mom6/ — não são bibliotecas .a.
cp_glob "build/gnu/${_mom6_target}/repro/*.o"   "${COUPLER_ROOT}/lib/mom6/"
cp_glob "build/gnu/${_mom6_target}/repro/*.mod" "${COUPLER_ROOT}/mod/mom6/"

# FMS: infraestrutura base
cp "build/gnu/shared/repro/libfms.a"      "${COUPLER_ROOT}/lib/fms/"
cp_glob "build/gnu/shared/repro/*.mod"    "${COUPLER_ROOT}/mod/fms/"

# =============================================================================
# Resumo final
# =============================================================================
log_sep
echo ""
timer_total "Build MOM6 completo em"
echo ""
log_ok "FMS    : build/gnu/shared/repro/libfms.a"
log_ok "MOM6   : build/gnu/${_mom6_target}/repro/MOM6"
log_ok "NUOPC  : build/gnu/nuopc_cap/repro/libmom6_nuopc.a"
echo ""
log_ok "Instalados em ${COUPLER_ROOT}/{lib,mod}/{fms,mom6,nuopc}/"
echo ""
log_info "Próximo passo: bash 3-install-coupler.bash"
log_sep
