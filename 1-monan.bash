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
#   3. Se o diretório MONAN-Model não existir, o script o baixa de
#      https://github.com/GTA-DIMNT-CPTEC/MONAN-Model. O acoplador acompanha a
#      branch feature/monan_coupler (MONAN_MODEL_BRANCH); o clone é feito no
#      último commit validado, e não na ponta, para que código ainda não
#      testado com o acoplador não entre sem decisão humana.
#      Esse ponto validado NÃO é constante neste script: vem do gitlink do
#      submódulo registrado no superprojeto (MONAN_MODEL_REF é derivado dele,
#      e só precisa ser definido à mão em clone avulso). Sobrescrevíveis por
#      ambiente, junto de MONAN_MODEL_URL e MONAN_MODEL_FOLLOW=true.
#
#      FLUXO DE ATUALIZAÇÃO DO MONAN-Model:
#        git -C models/atmos/MONAN-Model fetch origin feature/monan_coupler
#        git -C models/atmos/MONAN-Model checkout feature/monan_coupler
#        git -C models/atmos/MONAN-Model pull
#        bash 1-monan.bash                # avisa quantos commits à frente
#        <validar: 3-coupler.bash + test-sequential-split.bash>
#        # validado: commitar o gitlink JÁ fixa o novo ponto de referência —
#        # não há constante a editar neste script.
#        git -C <raiz> add models/atmos/MONAN-Model && git -C <raiz> commit
#   4. ROBUSTEZ A ATUALIZAÇÕES DO MONAN-Model. Até a v2 deste script, os
#      diretórios de origem dos .mod e .a eram uma LISTA FIXA de 17 caminhos.
#      Quando o MONAN acrescentava um pacote de física (um novo
#      src/core_atmosphere/physics/physics_*/), os .mod correspondentes
#      simplesmente não eram copiados — sem erro e sem aviso, porque ninguém
#      procurava por eles. A falha só aparecia depois, na compilação do
#      acoplador, como "Cannot open module file", ou pior: o build usava um
#      .mod ANTIGO remanescente em mod/monan2, produzindo binário inconsistente
#      com os fontes. Agora a descoberta é automática (find), a lista fixa
#      serve apenas de linha de base para RELATAR diretórios novos ou
#      desaparecidos, e os destinos são limpos antes da cópia.
#   5. Nada é escrito dentro da árvore do MONAN-Model. Os logs de make vão para
#      <raiz>/logs/. Gravá-los no diretório do modelo deixava o submódulo sujo
#      e podia bloquear `git checkout`/`git pull` na atualização seguinte.
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
#   export MONAN_MODEL_REF=<commit>      # só em clone avulso, sem superprojeto
MONAN_MODEL_URL="${MONAN_MODEL_URL:-https://github.com/GTA-DIMNT-CPTEC/MONAN-Model.git}"

# BRANCH x REF — dois papéis distintos, antes confundidos num único SHA.
#
#   MONAN_MODEL_BRANCH  linha de desenvolvimento que o acoplador acompanha.
#   MONAN_MODEL_REF     último commit dessa branch VALIDADO com o acoplador.
#
# Até a v2 existia só o REF, um SHA nu. Como a intenção é acompanhar a branch,
# o SHA ficava para trás a cada avanço dela — sem que nada relatasse a
# divergência, e sem que o próprio valor revelasse a que linha pertencia.
# Agora o REF é o ponto de validação (reprodutibilidade) e a BRANCH é o alvo
# (acompanhamento); a checagem de proveniência mais abaixo compara os dois.
MONAN_MODEL_BRANCH="${MONAN_MODEL_BRANCH:-feature/monan_coupler}"

# O SHA literal saiu daqui. O ponto validado JÁ está registrado no gitlink do
# submódulo, e commitar esse gitlink no superprojeto é exatamente o ato de
# declarar "esta revisão foi validada com o acoplador". Manter uma segunda
# cópia do mesmo dado numa constante criava duas fontes de verdade que
# divergiam em silêncio: quem atualizasse o submódulo e commitasse deixaria a
# constante para trás, e ninguém seria avisado.
#
# Vazio é estado legítimo (clone avulso, sem superprojeto): significa apenas
# que não há ponto validado registrado, e a checagem adiante reporta isso em
# vez de comparar contra nada.
MONAN_MODEL_SUB="models/atmos/MONAN-Model"
if [[ -z "${MONAN_MODEL_REF:-}" ]]; then
  MONAN_MODEL_REF="$(resolve_model_ref "${COUPLER_ROOT}" "${MONAN_MODEL_SUB}")"
fi

# Clone novo: no ponto validado, quando houver. Compilar automaticamente
# código nunca testado com o acoplador transformaria qualquer commit alheio num
# problema desta árvore. Sem ponto validado, só resta a ponta da branch.
# Para seguir a ponta deliberadamente:  export MONAN_MODEL_FOLLOW=true
MONAN_MODEL_FOLLOW="${MONAN_MODEL_FOLLOW:-false}"
if [[ "${MONAN_MODEL_FOLLOW}" == true || -z "${MONAN_MODEL_REF}" ]]; then
  _monan_clone_ref="${MONAN_MODEL_BRANCH}"
  [[ -z "${MONAN_MODEL_REF}" ]] \
    && log_warn "Sem gitlink do submódulo — clone novo iria para a ponta de ${MONAN_MODEL_BRANCH}." \
    || log_info "Clone novo seguiria a ponta de ${MONAN_MODEL_BRANCH} (MONAN_MODEL_FOLLOW=true)"
else
  _monan_clone_ref="${MONAN_MODEL_REF}"
fi
ensure_model_tree "${MONAN_MODEL}" "${COUPLER_ROOT}" "${MONAN_MODEL_SUB}" \
                  "${MONAN_MODEL_URL}" "${_monan_clone_ref}"

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

# ── Proveniência da árvore de fontes ─────────────────────────────────────────
# Lógica compartilhada com 2-mom.bash (include.bash): registra a revisão
# compilada e a compara com o ponto validado, sem jamais barrar a compilação.
report_model_provenance "${MONAN_MODEL}" "${MONAN_MODEL_BRANCH}" \
                        "${MONAN_MODEL_REF}" "MONAN-Model"

# ── Logs de make FORA da árvore do modelo ────────────────────────────────────
# Gravar make-*.log dentro de MONAN-Model deixa o submódulo sujo e pode
# bloquear o `git checkout` da próxima atualização.
MONAN_LOGDIR="${COUPLER_ROOT}/logs"
mkdir -p "${MONAN_LOGDIR}"

# Flags de compilação — comuns aos dois cores (array: expansão segura, sem
# depender de word-splitting de uma string).
MAKE_ARGS=(OPENMP=true USE_PIO2=false PRECISION=double AUTOCLEAN=true)

# ── ETAPA 1 — Core 'atmosphere' (compilação e cópia dos artefatos) ────────────
# A cópia DEVE ocorrer ANTES da compilação do 'init_atmosphere': com
# AUTOCLEAN=true, a troca de CORE= apaga os artefatos do core anterior.
log_step 1 2 "Core 'atmosphere' — compilação"
timer_start

make -j "${MAKE_JOBS}" "${MONAN_TARGET}" CORE=atmosphere "${MAKE_ARGS[@]}" 2>&1 \
  | tee "${MONAN_LOGDIR}/make-atmosphere.log"

timer_step "Core 'atmosphere' compilado"

log_step 1 2 "Core 'atmosphere' — cópia dos artefatos para ${MOD_ATM} / ${LIB_ATM}"

# ── Coleta dos artefatos: descoberta automática ──────────────────────────────
# A lista abaixo NÃO comanda a cópia; ela é a linha de base contra a qual o
# script compara o que encontrou. Manter uma lista fixa comandando a cópia era
# o ponto frágil: um diretório novo no MONAN-Model passava despercebido.
MONAN2_MOD_DIRS_BASE=(
  ./src/core_atmosphere
  ./src/core_atmosphere/diagnostics
  ./src/core_atmosphere/dynamics
  ./src/core_atmosphere/physics
  ./src/core_atmosphere/physics/physics_mmm
  ./src/core_atmosphere/physics/physics_monan
  ./src/core_atmosphere/physics/physics_noaa/UGWP
  ./src/core_atmosphere/physics/physics_noahmp/drivers/mpas
  ./src/core_atmosphere/physics/physics_noahmp/src
  ./src/core_atmosphere/physics/physics_noahmp/utility
  ./src/core_atmosphere/physics/physics_wrf
  ./src/core_atmosphere/utils
  ./src/driver
  ./src/external/SMIOL
  ./src/external/esmf_time_f90
  ./src/framework
  ./src/operators
)

# collect_artifacts <extensão> <destino> <rótulo> [baseline...]
#   Descobre todos os arquivos da extensão sob ./src, exceto os do core
#   'init_atmosphere' (que tem .mod e libdycore.a homônimos e vai para outro
#   destino), copia-os e relata divergências em relação à linha de base.
collect_artifacts() {
  local ext="$1" dest="$2" rotulo="$3"; shift 3
  local -a baseline=( "$@" )
  local -a files=() dirs=() novos=() sumidos=()
  local d f base

  mapfile -t files < <(find ./src -type f -name "*.${ext}" \
                        -not -path '*/core_init_atmosphere/*' | sort)
  if [[ ${#files[@]} -eq 0 ]]; then
    log_error "Nenhum .${ext} encontrado sob ./src — a compilação produziu algo?"
    return 1
  fi

  mapfile -t dirs < <(printf '%s\n' "${files[@]}" | xargs -r -n1 dirname | sort -u)

  # Diretórios novos: o caso que quebrava o build depois da atualização.
  if [[ ${#baseline[@]} -gt 0 ]]; then
    for d in "${dirs[@]}"; do
      if ! printf '%s\n' "${baseline[@]}" | grep -qxF "${d}"; then
        novos+=( "${d}" )
      fi
    done
    for d in "${baseline[@]}"; do
      if ! printf '%s\n' "${dirs[@]}" | grep -qxF "${d}"; then
        sumidos+=( "${d}" )
      fi
    done
  fi

  # Nomes homônimos em diretórios distintos. A detecção vem ANTES da cópia por
  # necessidade, não por estilo: `cp a/x.mod b/x.mod dest/` falha com "will not
  # overwrite just-created", e sob `set -e` o script morreria sem chegar a
  # avisar. A cópia abaixo é feita item a item justamente para tolerar o caso.
  local -a dups=()
  mapfile -t dups < <(printf '%s\n' "${files[@]}" | xargs -r -n1 basename \
                       | sort | uniq -d)
  if [[ ${#dups[@]} -gt 0 ]]; then
    log_warn "${rotulo}: nome(s) duplicado(s) em diretórios diferentes:"
    printf '          %s\n' "${dups[@]}" >&2
    log_warn "  Prevalece a última ocorrência em ordem alfabética de caminho;"
    log_warn "  confira qual versão o acoplador precisa."
  fi

  # Destino limpo: .mod ou .a órfão de versão anterior sobrevive ao `cp` e
  # produz binário inconsistente com os fontes, sem qualquer erro de link.
  rm -rf "${dest:?}"; mkdir -p "${dest}"
  for f in "${files[@]}"; do
    cp -f "${f}" "${dest}/"
  done

  log_ok "${rotulo}: ${#files[@]} arquivo(s) .${ext} de ${#dirs[@]} diretório(s) → ${dest}"

  if [[ ${#novos[@]} -gt 0 ]]; then
    log_warn "${rotulo}: ${#novos[@]} diretório(s) NOVO(S) no MONAN-Model:"
    printf '          %s\n' "${novos[@]}" >&2
    log_warn "  Foram copiados normalmente. Acrescente-os a MONAN2_MOD_DIRS_BASE"
    log_warn "  neste script para silenciar o aviso na próxima atualização."
  fi
  if [[ ${#sumidos[@]} -gt 0 ]]; then
    log_warn "${rotulo}: ${#sumidos[@]} diretório(s) da linha de base sem artefatos:"
    printf '          %s\n' "${sumidos[@]}" >&2
    log_warn "  Pode ser reorganização do MONAN-Model ou compilação parcial."
  fi

}

collect_artifacts mod "${MOD_ATM}" "Core 'atmosphere' (.mod)" \
                  "${MONAN2_MOD_DIRS_BASE[@]}"
collect_artifacts a   "${LIB_ATM}" "Core 'atmosphere' (.a)"

log_ok "Artefatos do 'atmosphere' copiados."

# ── ETAPA 2 — Core 'init_atmosphere' (gerador de condições iniciais) ──────────
# Pule com --skip-init-atm se não precisar gerar condições iniciais neste host.
if [[ "${SKIP_INIT_ATM}" == false ]]; then
  log_step 2 2 "Core 'init_atmosphere' — compilação"

  make -j "${MAKE_JOBS}" "${MONAN_TARGET}" CORE=init_atmosphere "${MAKE_ARGS[@]}" 2>&1 \
    | tee "${MONAN_LOGDIR}/make-init_atmosphere.log"

  timer_step "Core 'init_atmosphere' compilado"

  rm -rf "${MOD_INIT:?}" "${LIB_INIT:?}"
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

# A verificação é por PRESENÇA e por FRESCOR. Antes da limpeza do destino, uma
# biblioteca herdada de build anterior passava neste teste e o acoplador linkava
# contra código que não correspondia aos fontes — falha silenciosa, do tipo que
# só aparece como resultado numérico estranho semanas depois. O destino agora é
# limpo a cada execução, e a referência de tempo confirma isso.
_ref="${MONAN_LOGDIR}/make-atmosphere.log"
_miss=0
_stale=0
for _lib in "${MONAN2_LIBS[@]}"; do
  if [[ ! -f "${LIB_ATM}/${_lib}" ]]; then
    log_warn "${_lib}  <-- AUSENTE"
    _miss=$(( _miss + 1 ))
  elif [[ -f "${_ref}" && "${LIB_ATM}/${_lib}" -ot "${_ref}" ]]; then
    log_warn "${_lib}  <-- ANTERIOR a esta compilação"
    _stale=$(( _stale + 1 ))
  else
    log_ok "${_lib}"
  fi
done
if [[ ${_stale} -gt 0 ]]; then
  log_warn "${_stale} biblioteca(s) mais antiga(s) que o log desta execução."
  log_warn "  Indica que o make não as regerou. Confira ${_ref}."
fi
echo ""

if [[ ${_miss} -eq 0 ]]; then
  timer_total "Instalação do MONAN-A concluída em"
  echo ""
  log_ok "Módulos  : ${MOD_ATM}"
  log_ok "Libs     : ${LIB_ATM}"
  echo ""
  log_info "Próximo passo: bash 2-install-mom.bash"
else
  log_error "${_miss} biblioteca(s) ausente(s) — verifique ${MONAN_LOGDIR}/make-atmosphere.log"
  exit 1
fi
