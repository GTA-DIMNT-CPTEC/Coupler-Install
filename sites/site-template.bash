#!/bin/bash
# =============================================================================
# site-template.bash — Esqueleto de configuração de sítio (NOVA MÁQUINA)
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# COMO USAR
#   1. Copie este arquivo:   cp sites/site-template.bash sites/site-<host>.bash
#   2. Edite os valores marcados com  <<< AJUSTE >>>  para a sua máquina.
#   3. Aponte os scripts para ele e instale:
#         export SITE_ENV="$PWD/sites/site-<host>.bash"
#         bash install.bash            # (ou: bash build.bash)
#
# MECANISMO: cada parâmetro usa ':= valor' — só é aplicado se a variável ainda
# não estiver definida. Assim, qualquer 'export VAR=...' feito ANTES do source
# tem prioridade sobre o padrão definido aqui.
#
# Referência completa e comentada: sites/site-jaci.bash (Jaci / Cray XD2000).
# =============================================================================

# ── ESMF 8.9.1 ───────────────────────────────────────────────────────────────
# Raiz da instalação do ESMF e o esmf.mk dela derivado (ponto de verdade do
# ESMF: compilador e flags). O subcaminho codifica a configuração de build do
# ESMF; ajuste se o layout interno da sua instalação for diferente.
: "${ESMF_ROOT:=/caminho/para/esmf-8.9.1}"                          # <<< AJUSTE >>>
: "${ESMFMKFILE:=${ESMF_ROOT}/lib/libO/<config-esmf>/esmf.mk}"      # <<< AJUSTE >>>
export ESMF_ROOT ESMFMKFILE

# ── ESMF: diretórios de módulos e bibliotecas (derivados do esmf.mk) ──────────
# NÃO precisa ajustar: deriva ESMF_MOD (dir do esmf.mod) e ESMF_LIBDIR (dir da
# libesmf.a) a partir do ESMFMKFILE acima — fonte única de verdade do ESMF. O
# build do acoplador (MONAN-A com -DMPAS_EXTERNAL_ESMF_LIB) exige essas duas
# variáveis no ambiente; sem elas o 'use ESMF' cairia no stub interno do MPAS.
# Respeita override (só deriva o que ainda não estiver definido) e é
# auto-contido (o setenv do acoplador faz source desta config diretamente).
if [[ -f "${ESMFMKFILE}" ]]; then
  _esmf_mk_get() {
    printf 'include %s\n_v:\n\t@echo $(%s)\n' "${ESMFMKFILE}" "$1" \
      | make -s -f - _v 2>/dev/null
  }
  # ESMF_MOD — diretório do esmf.mod (entre os -I de ESMF_F90COMPILEPATHS).
  if [[ -z "${ESMF_MOD:-}" ]]; then
    for _p in $(_esmf_mk_get ESMF_F90COMPILEPATHS); do
      _p="${_p#-I}"
      if [[ -f "${_p}/esmf.mod" ]]; then ESMF_MOD="${_p}"; break; fi
    done
  fi
  # ESMF_LIBDIR — diretório da libesmf, via -L canônico (ESMF_F90LINKPATHS) e,
  # como rede de segurança, o diretório do próprio esmf.mk. Não usamos a
  # variável ESMF_LIBDIR do esmf.mk: ela não existe em todo build do ESMF.
  if [[ -z "${ESMF_LIBDIR:-}" ]]; then
    for _p in $(_esmf_mk_get ESMF_F90LINKPATHS); do
      _p="${_p#-L}"
      if [[ -e "${_p}/libesmf.a" || -e "${_p}/libesmf.so" ]]; then ESMF_LIBDIR="${_p}"; break; fi
    done
    [[ -z "${ESMF_LIBDIR:-}" ]] && ESMF_LIBDIR="$(cd "$(dirname "${ESMFMKFILE}")" && pwd)"
  fi
  unset _p
  unset -f _esmf_mk_get
  export ESMF_LIBDIR ESMF_MOD
fi

# ── Paralelismo de compilação ────────────────────────────────────────────────
# Jobs do 'make -j'. Para usar todos os núcleos: export MAKE_JOBS=$(nproc).
: "${MAKE_JOBS:=8}"

# ── Alvo de CPU e alvo de build do MONAN-A ───────────────────────────────────
# CPU_TARGET : módulo de targeting (em ambiente Cray). Ex.: craype-x86-turin
#              (Zen5), craype-x86-milan (Zen3). Fora de Cray, deixe vazio ("").
# MONAN_TARGET: alvo do Makefile do MONAN-Model para este host/toolchain.
: "${CPU_TARGET:=craype-x86-<arch>}"                                # <<< AJUSTE >>>
: "${MONAN_TARGET:=gfortran-coupler-<host>}"                        # <<< AJUSTE >>>

# ── Wrappers do compilador ───────────────────────────────────────────────────
# Em Cray, use os wrappers (ftn/cc). Em GNU/MPICH "puro", use mpif90/mpicc.
: "${FC:=ftn}"                                                      # <<< AJUSTE >>>
: "${CC:=cc}"                                                       # <<< AJUSTE >>>
: "${LD:=ftn}"                                                      # <<< AJUSTE >>>

# ── Bibliotecas estáticas do core 'atmosphere' do MONAN-A ────────────────────
# Conjunto verificado pelo instalador 1 e pelo setenv. Normalmente NÃO muda.
MONAN2_LIBS=(libframework.a libdycore.a libphys.a libops.a libsmiolf.a libsmiol.a)

# ── Módulos para compilar o MONAN-A (instalador 1) ───────────────────────────
# Lista MÍNIMA de compilação. O MPAS/MONAN-A usa dois NetCDFs (paralelo p/ I/O e
# serial p/ o link). Inclua HDF5 (o NetCDF-4 é construído sobre ele).
# <<< AJUSTE os nomes/versões de módulo para a sua máquina >>>
MODULES_MONAN=(
  "${CPU_TARGET}"
  # PrgEnv-gnu/<versão>
  # cray-hdf5/<versão>
  # cray-netcdf/<versão>
  # cray-parallel-netcdf/<versão>
  # METIS/<versão>
)

# ── Módulos para compilar o MOM6+SIS2+FMS (instalador 2) ─────────────────────
# MOM6/FMS usa NetCDF SERIAL (sobre HDF5). NÃO usar o parallel-netcdf aqui.
# <<< AJUSTE os nomes/versões de módulo para a sua máquina >>>
MODULES_MOM6=(
  "${CPU_TARGET}"
  # PrgEnv-gnu/<versão>
  # cray-hdf5/<versão>
  # cray-netcdf/<versão>
)
