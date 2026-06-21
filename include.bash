#!/bin/bash
# =============================================================================
# include.bash — Biblioteca de funções compartilhadas
# MONAN-A 2.0 × MOM6+SIS2 / NUOPC-ESMF 8.9.1
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
# Versão 1.2 — Junho 2026
#
# Deve ser carregada via 'source', nunca executada diretamente.
# Fornece: log colorizado, cronômetro, cópia segura de globs,
#          clone idempotente de repositórios git e verificação de
#          variáveis de ambiente obrigatórias.
#
# Uso nos instaladores (SCRIPT_DIR já definido):
#   source "${SCRIPT_DIR}/include.bash"
# =============================================================================

# ── Guarda contra execução direta ─────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Erro: carregue com 'source include.bash', não diretamente." >&2
  exit 1
fi

# ── Colorização ───────────────────────────────────────────────────────────────
# Ativada somente quando stdout é um terminal que suporta cores; caso
# contrário todas as variáveis ficam vazias (saída limpa em logs/arquivos).
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  _C_VD=$(tput setaf 2)    # verde   — OK / sucesso
  _C_AM=$(tput setaf 3)    # amarelo — aviso
  _C_VM=$(tput setaf 1)    # vermelho — erro
  _C_AZ=$(tput setaf 6)    # ciano   — informação
  _C_BD=$(tput bold)       # negrito — título de etapa
  _C_RS=$(tput sgr0)       # reset de atributos
else
  _C_VD="" ; _C_AM="" ; _C_VM="" ; _C_AZ="" ; _C_BD="" ; _C_RS=""
fi

# ── Funções de log padronizado ────────────────────────────────────────────────
#
#   log_info  "msg"       — informação geral (ciano)
#   log_ok    "msg"       — operação concluída com sucesso (verde)
#   log_warn  "msg"       — aviso não-fatal (amarelo, para stderr)
#   log_error "msg"       — erro fatal, antes de 'exit 1' (vermelho, stderr)
#   log_step  N T "desc"  — cabeçalho de etapa "==> [N/T] desc" (negrito)
#   log_sep               — separador visual ─────────────────
#
log_info()  { printf "${_C_AZ}  INFO  ${_C_RS}%s\n"   "$*"; }
log_ok()    { printf "${_C_VD}  OK    ${_C_RS}%s\n"   "$*"; }
log_warn()  { printf "${_C_AM}  AVISO ${_C_RS}%s\n"   "$*" >&2; }
log_error() { printf "${_C_VM}  ERRO  ${_C_RS}%s\n"   "$*" >&2; }
log_step()  { printf "\n${_C_BD}==> [%s/%s] %s${_C_RS}\n" "$1" "$2" "$3"; }
log_sep()   { printf "${_C_AZ}%s${_C_RS}\n" \
                "$(printf '─%.0s' $(seq 1 70))"; }

# ── Cronômetro (precisão: segundos) ───────────────────────────────────────────
#
#   timer_start            — marca o instante inicial (etapa e total)
#   timer_step  ["label"]  — exibe tempo desde o último timer_start/_step_reset
#                            e reinicia o cronômetro de etapa
#   timer_total ["label"]  — exibe tempo total desde timer_start
#
_TIMER_START=0
_TIMER_STEP=0

timer_start() {
  _TIMER_START=${SECONDS}
  _TIMER_STEP=${SECONDS}
}

timer_step() {
  local label="${1:-Etapa}"
  local elapsed=$(( SECONDS - _TIMER_STEP ))
  local m=$(( elapsed / 60 )) s=$(( elapsed % 60 ))
  if (( m > 0 )); then
    log_ok "${label}: ${m}min ${s}s"
  else
    log_ok "${label}: ${s}s"
  fi
  _TIMER_STEP=${SECONDS}   # reinicia cronômetro de etapa
}

timer_total() {
  local label="${1:-Tempo total}"
  local elapsed=$(( SECONDS - _TIMER_START ))
  local m=$(( elapsed / 60 )) s=$(( elapsed % 60 ))
  if (( m > 0 )); then
    log_ok "${label}: ${m}min ${s}s"
  else
    log_ok "${label}: ${s}s"
  fi
}

# ── cp_glob — cópia segura com glob, tolerante a diretórios vazios ────────────
#
# Uso: cp_glob <PADRÃO_GLOB> <DESTINO>
#
# Expande PADRÃO (ex.: "./src/core_atm/*.mod") e copia para DESTINO.
#   - Se nenhum arquivo casar: emite log_warn e retorna 0 (não aborta).
#   - Se a cópia falhar: retorna o código de saída do 'cp'.
#
cp_glob() {
  local pattern="$1" dest="$2"
  local -a files=()

  # nullglob: o glob literal não é passado ao cp quando não há correspondência.
  # A expansão de ${pattern} sem aspas é intencional (queremos o globbing).
  shopt -s nullglob
  # shellcheck disable=SC2206  # word splitting/globbing são desejados aqui
  files=( ${pattern} )
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    log_warn "cp_glob: nenhum arquivo encontrado em: ${pattern}"
    return 0
  fi
  cp "${files[@]}" "${dest}"
}

# ── clone_if_missing — clona um repositório git se ele estiver ausente ou vazio ─
#
# Uso: clone_if_missing <DIR> <URL> [REF] [--recursive]
#
#   DIR          Diretório de destino. Se já existir E contiver arquivos, nada é
#                feito (idempotente). Se não existir ou estiver vazio, baixa.
#   URL          URL do repositório git.
#   REF          (opcional) tag ou branch para checkout após o clone.
#   --recursive  (opcional) clona também os submódulos (--recursive).
#
# A ordem de REF e --recursive é livre. Retorna 0 se o diretório já estava
# populado ou se o clone teve sucesso; retorna 1 se o git não estiver
# disponível ou falhar.
#
clone_if_missing() {
  local dir="$1" url="$2"
  shift 2

  local recursive=false ref=""
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --recursive) recursive=true ;;
      *)           ref="${arg}"   ;;
    esac
  done

  # Idempotência: só considera "já baixado" um diretório que exista E contenha
  # algo. Um diretório vazio (p.ex. resíduo de clone interrompido ou placeholder
  # de submódulo) é tratado como ausente, permitindo o download.
  if [[ -d "${dir}" ]] && \
     [[ -n "$(find "${dir}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    log_info "Repositório já presente (download ignorado): ${dir}"
    return 0
  fi
  if [[ -d "${dir}" ]]; then
    log_warn "Diretório existe porém vazio — prosseguindo com o download: ${dir}"
  fi

  if ! command -v git &>/dev/null; then
    log_error "git não encontrado no PATH — necessário para baixar ${url}"
    return 1
  fi

  log_info "Baixando ${url}"
  log_info "  → ${dir}"
  if [[ "${recursive}" == true ]]; then
    git clone --recursive "${url}" "${dir}" || return 1
  else
    git clone "${url}" "${dir}" || return 1
  fi

  if [[ -n "${ref}" ]]; then
    log_info "Checkout da referência: ${ref}"
    git -C "${dir}" checkout "${ref}" || return 1
    [[ "${recursive}" == true ]] && \
      git -C "${dir}" submodule update --init --recursive || true
  fi

  log_ok "Download concluído: ${dir}"
}

# ── clone_recursive_if_missing — clona o sistema acoplado com submódulos ──────
#
# Uso: clone_recursive_if_missing <DIR> <URL> [BRANCH]
#
# Clona <URL> em <DIR> com 'git clone --recursive' (traz MONAN-Model e
# MOM6-examples e os submódulos aninhados deste último). Se <DIR> já for um
# repositório git, apenas sincroniza os submódulos (idempotente). Usado pelo
# install.bash como porta de entrada única do download.
#
clone_recursive_if_missing() {
  local dir="$1" url="$2" branch="${3:-}"

  if git -C "${dir}" rev-parse --git-dir &>/dev/null; then
    log_info "Acoplador já presente — sincronizando submódulos: ${dir}"
    git -C "${dir}" submodule update --init --recursive || return 1
    log_ok "Submódulos atualizados."
    return 0
  fi

  if ! command -v git &>/dev/null; then
    log_error "git não encontrado no PATH — necessário para baixar ${url}"
    return 1
  fi

  log_info "Clonando (recursivo) ${url} [branch: ${branch:-padrão}]"
  log_info "  → ${dir}"
  if [[ -n "${branch}" ]]; then
    git clone --recursive --branch "${branch}" "${url}" "${dir}" || return 1
  else
    git clone --recursive "${url}" "${dir}" || return 1
  fi
  log_ok "Sistema acoplado baixado: ${dir}"
}

# ── ensure_model_tree — garante a árvore de fontes de um modelo ───────────────
#
# Uso: ensure_model_tree <DIR> <COUPLER_ROOT> <SUBPATH> <URL> [REF]
#
# Estratégia, em ordem de preferência:
#   1. Já presente e populado → nada a fazer.
#   2. É submódulo de COUPLER_ROOT (consta no .gitmodules) → inicializa com
#      'git submodule update --init --recursive -- SUBPATH'.
#   3. Fallback legado (sem submódulos) → 'clone_if_missing' direto com REF.
#
ensure_model_tree() {
  local dir="$1" root="$2" sub="$3" url="$4" ref="${5:-}"

  if [[ -d "${dir}" ]] && \
     [[ -n "$(find "${dir}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    log_info "Fonte já presente: ${dir}"
    return 0
  fi

  if [[ -f "${root}/.gitmodules" ]] && \
     git -C "${root}" config --file .gitmodules --get-regexp '\.path$' 2>/dev/null \
       | awk '{print $2}' | grep -qx "${sub}"; then
    log_info "Inicializando submódulo: ${sub}"
    git -C "${root}" submodule update --init --recursive -- "${sub}" || return 1
    log_ok "Submódulo pronto: ${sub}"
    return 0
  fi

  log_warn "Sem submódulo para ${sub} — usando clone direto (modo legado)."
  clone_if_missing "${dir}" "${url}" ${ref:+"${ref}"} --recursive
}

# ── resolve_coupler_root — define e valida COUPLER_ROOT ───────────────────────
#
# Os scripts de instalação vivem em repositório próprio, FORA da árvore do
# acoplador; portanto COUPLER_ROOT não é mais derivável da localização do script.
# Ordem de resolução: $COUPLER_ROOT (ambiente, p.ex. exportado pelo install.bash)
# → ./MONAN-Coupler (diretório atual). Valida a existência e normaliza para
# caminho absoluto, exportando o resultado.
#
resolve_coupler_root() {
  local cr="${COUPLER_ROOT:-$(pwd)/MONAN-Coupler}"
  if [[ ! -d "${cr}" ]]; then
    log_error "Árvore do acoplador não encontrada: ${cr}"
    log_info  "Baixe o sistema primeiro:  bash install.bash"
    log_info  "Ou aponte a raiz já clonada:  export COUPLER_ROOT=/caminho/MONAN-Coupler"
    exit 1
  fi
  COUPLER_ROOT="$(cd "${cr}" && pwd)"
  export COUPLER_ROOT
}

# ── check_var — verifica variáveis de ambiente obrigatórias ───────────────────
#
# Uso: check_var NOME_VAR1 NOME_VAR2 ...
# Emite log_error para cada variável vazia e retorna 1 se alguma falhar.
#
check_var() {
  local rc=0 v
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then
      log_error "Variável obrigatória não definida: ${v}"
      rc=1
    fi
  done
  return ${rc}
}

# ── find_first_path — define VAR com o 1º candidato existente ──────────────────
#
# Uso: find_first_path <VAR_DESTINO> <candidato1> [candidato2 ...]
#
# Percorre os candidatos (ignora vazios) e, no primeiro que existir, atribui o
# caminho à variável nomeada e retorna 0. Retorna 1 se nenhum existir.
#
find_first_path() {
  local __var="$1"; shift
  local c
  for c in "$@"; do
    if [[ -n "${c}" && -e "${c}" ]]; then
      printf -v "${__var}" '%s' "${c}"
      return 0
    fi
  done
  return 1
}

# ── resolve_site_env — localiza o arquivo de configuração de sítio ────────────
#
# Uso: resolve_site_env <DIR_DO_INSTALADOR>
#
# Procura site-jaci.bash em vários locais, na ordem:
#   1. $SITE_ENV (se já definido pelo usuário/install.bash)
#   2. <DIR>/sites/site-jaci.bash      (layout organizado — recomendado)
#   3. <DIR>/site-jaci.bash            (raiz do instalador — legado achatado)
#   4. <DIR>/install/site-jaci.bash    (subpasta install/)
#   5. ${COUPLER_ROOT}/run/setenv-site.bash    (cópia deixada pelo install.bash)
#   6. ${COUPLER_ROOT}/install/site-jaci.bash  (legado)
# Em sucesso, exporta SITE_ENV (caminho absoluto) e retorna 0; senão, retorna 1.
#
resolve_site_env() {
  local dir="$1" c
  local -a candidatos=()
  [[ -n "${SITE_ENV:-}" ]]        && candidatos+=( "${SITE_ENV}" )
  candidatos+=( "${dir}/sites/site-jaci.bash" \
                "${dir}/site-jaci.bash" \
                "${dir}/install/site-jaci.bash" )
  [[ -n "${COUPLER_ROOT:-}" ]]    && candidatos+=( "${COUPLER_ROOT}/run/setenv-site.bash" \
                                                   "${COUPLER_ROOT}/install/site-jaci.bash" )
  for c in "${candidatos[@]}"; do
    if [[ -f "${c}" ]]; then
      SITE_ENV="$(cd "$(dirname "${c}")" && pwd)/$(basename "${c}")"
      export SITE_ENV
      return 0
    fi
  done
  return 1
}

# ── load_site_env — carrega a configuração de sítio (ESMF, módulos, alvos) ─────
#
# Uso: load_site_env <DIR_DO_INSTALADOR>
#
# Resolve o arquivo via resolve_site_env e faz source. Como arrays e exports do
# site são atribuições globais, propagam-se ao chamador mesmo sendo sourced aqui.
# Aborta (exit 1) com mensagem precisa se nenhum candidato existir.
#
load_site_env() {
  local dir="$1"
  if ! resolve_site_env "${dir}"; then
    log_error "Configuração de sítio (site-jaci.bash) não encontrada."
    log_info  "Locais procurados:"
    log_info  "    • \$SITE_ENV ........... ${SITE_ENV:-<não definido>}"
    log_info  "    • ${dir}/sites/site-jaci.bash"
    log_info  "    • ${dir}/site-jaci.bash"
    log_info  "    • ${dir}/install/site-jaci.bash"
    [[ -n "${COUPLER_ROOT:-}" ]] && \
    log_info  "    • ${COUPLER_ROOT}/install/site-jaci.bash"
    log_info  "Soluções: coloque site-jaci.bash em sites/ (ou junto aos scripts),"
    log_info  "ou exporte SITE_ENV=/caminho/para/site-jaci.bash e tente de novo."
    exit 1
  fi
  log_info "Config de sítio: ${SITE_ENV}"
  # shellcheck source=/dev/null
  source "${SITE_ENV}"
}

# ── resolve_mkmf_template — localiza o template mkmf Cray/GNU ──────────────────
#
# Uso: resolve_mkmf_template <DIR_DO_INSTALADOR>
#
# Procura cray-gnu-monan.mk, na ordem:
#   1. $MKMF_TEMPLATE_SRC (se já definido)
#   2. <DIR>/templates/cray-gnu-monan.mk      (layout recomendado)
#   3. <DIR>/cray-gnu-monan.mk                (repo do instalador achatado)
#   4. <DIR>/install/templates/cray-gnu-monan.mk
#   5. ${COUPLER_ROOT}/install/templates/cray-gnu-monan.mk
# Em sucesso, exporta MKMF_TEMPLATE_SRC (absoluto) e retorna 0; senão retorna 1.
#
resolve_mkmf_template() {
  local dir="$1" t
  if find_first_path t \
       "${MKMF_TEMPLATE_SRC:-}" \
       "${dir}/templates/cray-gnu-monan.mk" \
       "${dir}/cray-gnu-monan.mk" \
       "${dir}/install/templates/cray-gnu-monan.mk" \
       "${COUPLER_ROOT:+${COUPLER_ROOT}/install/templates/cray-gnu-monan.mk}"; then
    MKMF_TEMPLATE_SRC="$(cd "$(dirname "${t}")" && pwd)/$(basename "${t}")"
    export MKMF_TEMPLATE_SRC
    return 0
  fi
  return 1
}

# ── load_modules — purga, carrega a lista de módulos e a exibe ────────────────
#
# Uso: load_modules <modulo1> <modulo2> ...   (ex.: load_modules "${MODULES_MONAN[@]}")
#
# Encapsula 'module purge' + 'module load' de cada item + a listagem formatada,
# escondendo o idioma 'module list | grep | sed' dos scripts chamadores.
#
load_modules() {
  local m
  module purge
  for m in "$@"; do module load "${m}"; done
  log_info "Módulos carregados:"
  module list 2>&1 | grep -E '^\s+[0-9]+\)' | sed 's/^/    /'
}
