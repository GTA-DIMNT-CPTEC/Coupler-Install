#!/bin/bash
# =============================================================================
# domain-mom6.bash — Divisão de domínio (domain decomposition) do MOM6+SIS2.
# Calcula um LAYOUT (NIPROC × NJPROC) equilibrado e gera o mask_table do FMS,
# eliminando os blocos 100% terra (land tiles) — reduzindo os PETs efetivos
# que o componente oceânico exige no acoplador NUOPC/ESMF.
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# IMPLEMENTAÇÃO 100% SHELL (sem Python): a leitura do array de topografia é
# delegada ao 'ncdump' (do módulo cray-netcdf) e o mascaramento é feito em
# 'awk' (POSIX). Não há dependência de numpy/netCDF4.
#
# CONTEXTO
#   No MOM6 o domínio horizontal é fatiado em NIPROC×NJPROC blocos (LAYOUT).
#   Como boa parte da grade é continente, muitos blocos são totalmente terra
#   e não precisam de PE. O FMS lê um mask_table que lista esses blocos; assim
#   os PETs efetivos = NIPROC*NJPROC − (blocos mascarados). É esse número que
#   o componente MOM6 pede no petList do NUOPC.
#
# USO (a partir de qualquer diretório):
#   bash domain-mom6.bash --topog ARQ.nc (--pes N | --layout NI,NJ) [OPÇÕES]
#
# OPÇÕES:
#   --topog ARQ.nc      (obrigatório) ocean_topog.nc (ou ocean_mask.nc) com o
#                       campo de profundidade/máscara. As dimensões da grade
#                       (NI_G, NJ_G) são lidas deste arquivo.
#   --pes N             Nº de blocos (NIPROC*NJPROC) desejado. O script fatora N
#                       e sugere o LAYOUT mais equilibrado (blocos quadrados).
#   --layout NI,NJ      LAYOUT explícito (NIPROC,NJPROC). Tem prioridade sobre --pes.
#   --min-depth D       Célula é OCEANO se profundidade > D (padrão: 0).
#                       Ignorado para variáveis de máscara (wet/mask: ocean = >0,5).
#   --depth-var NOME    Força o nome da variável (auto: depth, D, wet, mask).
#   --out ARQ           Caminho do mask_table de saída
#                       (padrão: mask_table.<Nmask>.<NI>x<NJ> no diretório atual).
#   --help, -h          Esta mensagem.
#
# SAÍDA
#   Um arquivo mask_table no formato do FMS:
#       linha 1 : número de blocos mascarados
#       linha 2 : NIPROC,NJPROC
#       demais  : i,j (1-based) de cada bloco 100% terra
#   E um resumo com o que inserir no MOM_input / SIS_input.
#
# REQUISITOS
#   ncdump (módulo cray-netcdf) e awk. Não usa Python.
#   Não depende do COUPLER_ROOT nem do ESMF — opera só sobre a topografia.
# =============================================================================
set -euo pipefail

# ── Âncora determinística ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Biblioteca de log (reusa include.bash do instalador, se presente) ─────────
if [[ -f "${SCRIPT_DIR}/include.bash" ]]; then
  # shellcheck source=include.bash
  source "${SCRIPT_DIR}/include.bash"
else
  if [[ -t 1 ]] && command -v tput &>/dev/null && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    _C_VD=$(tput setaf 2); _C_AM=$(tput setaf 3); _C_VM=$(tput setaf 1)
    _C_AZ=$(tput setaf 6); _C_BD=$(tput bold);   _C_RS=$(tput sgr0)
  else
    _C_VD=""; _C_AM=""; _C_VM=""; _C_AZ=""; _C_BD=""; _C_RS=""
  fi
  log_info()  { printf "${_C_AZ}  INFO  ${_C_RS}%s\n" "$*"; }
  log_ok()    { printf "${_C_VD}  OK    ${_C_RS}%s\n" "$*"; }
  log_warn()  { printf "${_C_AM}  AVISO ${_C_RS}%s\n" "$*" >&2; }
  log_error() { printf "${_C_VM}  ERRO  ${_C_RS}%s\n" "$*" >&2; }
  log_step()  { printf "\n${_C_BD}==> [%s/%s] %s${_C_RS}\n" "$1" "$2" "$3"; }
  log_sep()   { printf "${_C_AZ}%s${_C_RS}\n" "$(printf '─%.0s' $(seq 1 70))"; }
fi

# ── Ajuda ─────────────────────────────────────────────────────────────────────
usage() {
  cat << 'EOF'
Uso: bash domain-mom6.bash --topog ARQ.nc (--pes N | --layout NI,NJ) [OPÇÕES]

  Calcula um LAYOUT (NIPROC × NJPROC) equilibrado e gera o mask_table do FMS
  para o MOM6+SIS2, eliminando blocos 100% terra (reduz os PETs do oceano).
  Implementação 100% shell: ncdump (cray-netcdf) + awk, sem Python.

Opções:
  --topog ARQ.nc    (obrigatório) topografia/máscara (lê NI_G, NJ_G e o oceano).
  --pes N           Nº de blocos desejado; fatora N e sugere o LAYOUT.
  --layout NI,NJ    LAYOUT explícito (prioritário sobre --pes).
  --min-depth D     Oceano se profundidade > D (padrão: 0).
  --depth-var NOME  Força a variável (auto: depth, D, wet, mask).
  --out ARQ         Saída (padrão: mask_table.<Nmask>.<NI>x<NJ>).
  --help, -h        Esta mensagem.

Exemplos:
  bash domain-mom6.bash --topog INPUT/ocean_topog.nc --pes 128
  bash domain-mom6.bash --topog INPUT/ocean_topog.nc --layout 16,8
EOF
  exit 0
}

# ── Análise de opções ─────────────────────────────────────────────────────────
TOPOG=""
PES=0
NI_IN=0
NJ_IN=0
MIN_DEPTH=0
DEPTH_VAR=""
OUTFILE=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topog)     TOPOG="${2:?--topog exige um arquivo}"; shift 2 ;;
    --pes)       PES="${2:?--pes exige um número}"; shift 2 ;;
    --layout)    _lay="${2:?--layout exige NI,NJ}"; shift 2
                 if [[ ! "${_lay}" =~ ^[0-9]+,[0-9]+$ ]]; then
                   log_error "--layout malformado: '${_lay}' (use NI,NJ, ex.: 16,8)"; exit 1
                 fi
                 NI_IN="${_lay%,*}"; NJ_IN="${_lay#*,}" ;;
    --min-depth) MIN_DEPTH="${2:?--min-depth exige um valor}"; shift 2 ;;
    --depth-var) DEPTH_VAR="${2:?--depth-var exige um nome}"; shift 2 ;;
    --out)       OUTFILE="${2:?--out exige um caminho}"; shift 2 ;;
    --help|-h)   usage ;;
    *) log_error "Opção desconhecida: $1   (use --help)"; exit 1 ;;
  esac
done
unset _lay 2>/dev/null || true

# ── Validações ────────────────────────────────────────────────────────────────
if [[ -z "${TOPOG}" ]]; then
  log_error "--topog é obrigatório (informe ocean_topog.nc ou ocean_mask.nc)."
  exit 1
fi
if [[ ! -f "${TOPOG}" ]]; then
  log_error "Arquivo de topografia não encontrado: ${TOPOG}"
  exit 1
fi
if [[ "${NI_IN}" -gt 0 && "${NJ_IN}" -gt 0 ]]; then
  MODE="layout"
elif [[ "${PES}" -gt 0 ]]; then
  MODE="pes"
else
  log_error "Informe --pes N (sugere o LAYOUT) ou --layout NI,NJ (explícito)."
  exit 1
fi
if ! command -v ncdump &>/dev/null; then
  log_error "ncdump não encontrado no PATH."
  log_info  "Na Jaci:  module load cray-netcdf"
  exit 1
fi

# ── Leitura do cabeçalho (ncdump -h): variável, dimensões e tamanhos ──────────
# Estratégia robusta a nomes de dimensão: localiza a declaração da variável
# escolhida e toma as DUAS ÚLTIMAS dimensões como (j, i) = (NJ_G, NI_G).
HDR="$(ncdump -h "${TOPOG}")"

VAR=""
for _v in ${DEPTH_VAR} depth D wet mask; do
  [[ -z "${_v}" ]] && continue
  if grep -qE "^[[:space:]]+[A-Za-z0-9_]+ ${_v}\(" <<< "${HDR}"; then
    VAR="${_v}"; break
  fi
done
if [[ -z "${VAR}" ]]; then
  log_error "Nenhuma variável de profundidade/máscara encontrada (depth, D, wet, mask)."
  log_info  "Variáveis no arquivo:"
  grep -E "^[[:space:]]+[A-Za-z0-9_]+ [A-Za-z0-9_]+\(" <<< "${HDR}" | sed 's/^/    /' >&2
  log_info  "Force com --depth-var NOME."
  exit 1
fi

# Lista de dimensões da variável (conteúdo entre parênteses)
_decl="$(grep -E "^[[:space:]]+[A-Za-z0-9_]+ ${VAR}\(" <<< "${HDR}" | head -1)"
_dims="$(sed -E 's/.*\(([^)]*)\).*/\1/' <<< "${_decl}" | tr -d ' ')"   # ex.: ny,nx
_ndim="$(awk -F',' '{print NF}' <<< "${_dims}")"
if [[ "${_ndim}" -lt 2 ]]; then
  log_error "Variável '${VAR}' não é 2D (dims: ${_dims})."
  exit 1
fi
DIM_J="$(awk -F',' '{print $(NF-1)}' <<< "${_dims}")"   # penúltima = j (y)
DIM_I="$(awk -F',' '{print $(NF)}'   <<< "${_dims}")"   # última    = i (x)

_dim_size() {  # imprime o tamanho da dimensão $1 a partir do cabeçalho
  grep -E "^[[:space:]]*$1 = [0-9]+ ;" <<< "${HDR}" | sed -E 's/.*= *([0-9]+).*/\1/' | head -1
}
NJ_G="$(_dim_size "${DIM_J}")"
NI_G="$(_dim_size "${DIM_I}")"
if [[ -z "${NI_G}" || -z "${NJ_G}" ]]; then
  log_error "Falha ao obter dimensões da variável '${VAR}' (j=${DIM_J}, i=${DIM_I})."
  exit 1
fi

# Limiar de oceano: profundidade > MIN_DEPTH; máscara (wet/mask): > 0,5.
_vl="$(printf '%s' "${VAR}" | tr '[:upper:]' '[:lower:]')"
if [[ "${_vl}" == "wet" || "${_vl}" == "mask" ]]; then
  THRESH="0.5"
else
  THRESH="${MIN_DEPTH}"
fi

# Validação do LAYOUT explícito contra a grade
if [[ "${MODE}" == "layout" ]]; then
  if (( NI_IN > NI_G || NJ_IN > NJ_G )); then
    log_error "LAYOUT ${NI_IN}×${NJ_IN} excede a grade ${NI_G}×${NJ_G}."
    exit 1
  fi
fi

# ── Núcleo em awk: lê o array (ncdump -v), mascara e escreve o mask_table ──────
# Toda a aritmética de blocos usa uma soma de prefixos 2D (imagem integral) do
# oceano, calculada UMA vez; assim a avaliação de cada LAYOUT candidato é O(1)
# por bloco. O awk também grava o mask_table diretamente.
AWK_PROG="$(mktemp /tmp/domain-mom6.XXXXXX.awk)"
trap 'rm -f "${AWK_PROG}"' EXIT

cat > "${AWK_PROG}" << 'AWKEOF'
# Variáveis injetadas por -v: NI, NJ, THRESH, MODE, PES, NIP, NJP, OUTREQ, VAR
function maxv(a,b){ return a>b?a:b }
function minv(a,b){ return a<b?a:b }

# Fronteiras contíguas de 'n' pontos em 'parts' blocos (tamanhos diferem em ≤1).
function bounds(n, parts, S, E,   base, rem, k, s, sz) {
  base = int(n / parts); rem = n % parts; s = 0
  for (k = 1; k <= parts; k++) {
    sz = base + (k <= rem ? 1 : 0)
    S[k] = s; E[k] = s + sz; s += sz
  }
}

# Conta oceano num retângulo [i0,i1)×[j0,j1) via soma de prefixos PS.
function rectsum(i0, i1, j0, j1) {
  return PS[j1*W + i1] - PS[j0*W + i1] - PS[j1*W + i0] + PS[j0*W + i0]
}

# Nº de blocos 100% terra para o LAYOUT (nip,njp).
function nmasked(nip, njp,   IS, IE, JS, JE, ti, tj, m) {
  bounds(NI, nip, IS, IE); bounds(NJ, njp, JS, JE); m = 0
  for (tj = 1; tj <= njp; tj++)
    for (ti = 1; ti <= nip; ti++)
      if (rectsum(IS[ti], IE[ti], JS[tj], JE[tj]) == 0) m++
  return m
}

BEGIN { collect = 0; idx = 0 }

# Início do bloco de dados da nossa variável: " VAR = ..."
$0 ~ ("^[[:space:]]*" VAR "[[:space:]]*=") { collect = 1; sub(/^[^=]*=/, "", $0) }

collect {
  line = $0; fin = 0
  if (index(line, ";") > 0) { sub(/;.*/, "", line); fin = 1 }
  n = split(line, a, /[, \t]+/)
  for (k = 1; k <= n; k++) {
    tok = a[k]
    if (tok == "") continue
    ocean[idx] = (tok == "_") ? 0 : ((tok + 0) > THRESH ? 1 : 0)
    idx++
  }
  if (fin) collect = 0
}

END {
  total = NI * NJ
  if (idx != total)
    print "WARN Lidos " idx " valores, esperados " total " (verifique a variável/arquivo)."

  # Soma de prefixos 2D: PS[j*W + i], i em 0..NI, j em 0..NJ
  W = NI + 1
  for (i = 0; i <= NI; i++) PS[i] = 0
  for (j = 1; j <= NJ; j++) {
    PS[j*W + 0] = 0; rb = (j-1) * NI
    for (i = 1; i <= NI; i++) {
      o = ocean[rb + (i-1)] + 0
      PS[j*W + i] = o + PS[(j-1)*W + i] + PS[j*W + (i-1)] - PS[(j-1)*W + (i-1)]
    }
  }
  oc_total = PS[NJ*W + NI]
  print "DIMS VAR=" VAR " NI_G=" NI " NJ_G=" NJ " OCEAN=" oc_total " TOTAL=" total

  # Escolha do LAYOUT
  if (MODE == "pes") {
    P = PES; ncand = 0
    for (a1 = 1; a1*a1 <= P; a1++) {
      if (P % a1 != 0) continue
      b1 = P / a1
      ncand++; CA[ncand] = a1; CB[ncand] = b1
      if (a1 != b1) { ncand++; CA[ncand] = b1; CB[ncand] = a1 }
    }
    for (c = 1; c <= ncand; c++) {
      a1 = CA[c]; b1 = CB[c]
      ti = NI / a1; tj = NJ / b1
      even = (NI % a1 == 0 && NJ % b1 == 0)
      aspect = maxv(ti, tj) / (minv(ti, tj) + 1e-9)
      tiny = (minv(ti, tj) < 4) ? 1 : 0
      SC[c] = aspect + (even ? 0 : 0.5) + tiny * 5
      EV[c] = even
    }
    used_lim = (ncand < 6) ? ncand : 6
    for (r = 1; r <= used_lim; r++) {
      bi = 0; bs = 1e18
      for (c = 1; c <= ncand; c++)
        if (!UD[c] && SC[c] < bs) { bs = SC[c]; bi = c }
      UD[bi] = 1
      a1 = CA[bi]; b1 = CB[bi]
      nm = nmasked(a1, b1)
      printf "CAND NI=%d NJ=%d TIL=%dx%d EVEN=%d NMASK=%d EFF=%d\n",
             a1, b1, int(NI/a1), int(NJ/b1), EV[bi], nm, a1*b1 - nm
      if (r == 1) { nip = a1; njp = b1 }
    }
  } else {
    nip = NIP; njp = NJP
  }

  bounds(NI, nip, IS, IE); bounds(NJ, njp, JS, JE)
  nmask = 0
  for (tj = 1; tj <= njp; tj++)
    for (ti = 1; ti <= nip; ti++)
      if (rectsum(IS[ti], IE[ti], JS[tj], JE[tj]) == 0) {
        nmask++; MI[nmask] = ti; MJ[nmask] = tj
      }

  out = OUTREQ
  if (out == "") out = "mask_table." nmask "." nip "x" njp

  print nmask > out
  print nip "," njp > out
  for (m = 1; m <= nmask; m++) print MI[m] "," MJ[m] > out
  close(out)

  printf "CHOSEN NI=%d NJ=%d TIL_I=%.1f TIL_J=%.1f\n", nip, njp, NI/nip, NJ/njp
  printf "MASK NMASK=%d TOTAL=%d EFF=%d OUT=%s\n", nmask, nip*njp, nip*njp - nmask, out

  if (minv(NI/nip, NJ/njp) < 4)
    print "WARN Blocos pequenos (min " minv(NI/nip, NJ/njp) " pts/bloco): pode degradar o halo."
  if (NI % nip != 0 || NJ % njp != 0)
    print "WARN Divisão não exata: blocos de borda ficam com tamanho diferente."
  if (nmask == 0)
    print "WARN Nenhum bloco 100% terra: mask_table desnecessário (não defina MASKTABLE)."
}
AWKEOF

# ── Execução ──────────────────────────────────────────────────────────────────
log_sep
log_info "Divisão de domínio MOM6+SIS2 — INPE / CGCT / DIMNT (100% shell)"
log_info "Topografia: ${TOPOG}"
[[ "${MODE}" == "pes" ]] \
  && log_info "Modo: sugerir LAYOUT para ${PES} blocos" \
  || log_info "Modo: LAYOUT explícito ${NI_IN}×${NJ_IN}"
log_sep

PY_OUT="$(mktemp /tmp/domain-mom6.out.XXXXXX)"
trap 'rm -f "${AWK_PROG}" "${PY_OUT}"' EXIT

if ! ncdump -v "${VAR}" "${TOPOG}" \
     | awk -v NI="${NI_G}" -v NJ="${NJ_G}" -v THRESH="${THRESH}" \
           -v MODE="${MODE}" -v PES="${PES}" -v NIP="${NI_IN}" -v NJP="${NJ_IN}" \
           -v OUTREQ="${OUTFILE}" -v VAR="${VAR}" \
           -f "${AWK_PROG}" > "${PY_OUT}"; then
  log_error "Falha ao ler/processar a topografia (ncdump/awk)."
  exit 1
fi

# ── Parse e apresentação ──────────────────────────────────────────────────────
NI=""; NJ=""; NMASK=""; TOTAL=""; EFF=""; OUT=""; OCEAN_FRAC=""
_cand_header=false

while IFS= read -r line; do
  case "${line}" in
    WARN*)  log_warn "${line#WARN }" ;;
    DIMS*)
      _ni_g="$(sed -n 's/.*NI_G=\([0-9]*\).*/\1/p' <<< "${line}")"
      _nj_g="$(sed -n 's/.*NJ_G=\([0-9]*\).*/\1/p' <<< "${line}")"
      _var="$(sed -n 's/.*VAR=\([^ ]*\).*/\1/p'    <<< "${line}")"
      _ocean="$(sed -n 's/.*OCEAN=\([0-9]*\).*/\1/p' <<< "${line}")"
      _tot="$(sed -n 's/.*TOTAL=\([0-9]*\).*/\1/p'   <<< "${line}")"
      OCEAN_FRAC="$(awk "BEGIN{printf \"%.1f\", 100*${_ocean}/${_tot}}")"
      log_ok "Grade: ${_ni_g} × ${_nj_g}  (variável '${_var}', oceano ${OCEAN_FRAC}%)"
      ;;
    CAND*)
      if [[ "${_cand_header}" == false ]]; then
        log_step 1 2 "Candidatos de LAYOUT (ordenados; 1º = escolhido)"
        printf "       %-10s %-12s %-6s %-8s %-8s\n" "LAYOUT" "BLOCO(pts)" "EXATO" "MASCAR." "PETs"
        _cand_header=true
      fi
      _a="$(sed -n 's/.*NI=\([0-9]*\).*/\1/p'    <<< "${line}")"
      _b="$(sed -n 's/.*NJ=\([0-9]*\).*/\1/p'    <<< "${line}")"
      _til="$(sed -n 's/.*TIL=\([0-9x]*\).*/\1/p' <<< "${line}")"
      _evn="$(sed -n 's/.*EVEN=\([0-9]*\).*/\1/p' <<< "${line}")"
      _nm="$(sed -n 's/.*NMASK=\([0-9]*\).*/\1/p' <<< "${line}")"
      _ef="$(sed -n 's/.*EFF=\([0-9]*\).*/\1/p'   <<< "${line}")"
      [[ "${_evn}" == "1" ]] && _ev="sim" || _ev="não"
      printf "       %-10s %-12s %-6s %-8s %-8s\n" "${_a}×${_b}" "${_til}" "${_ev}" "${_nm}" "${_ef}"
      ;;
    CHOSEN*)
      NI="$(sed -n 's/.*NI=\([0-9]*\).*/\1/p' <<< "${line}")"
      NJ="$(sed -n 's/.*NJ=\([0-9]*\).*/\1/p' <<< "${line}")"
      ;;
    MASK*)
      NMASK="$(sed -n 's/.*NMASK=\([0-9]*\).*/\1/p' <<< "${line}")"
      TOTAL="$(sed -n 's/.*TOTAL=\([0-9]*\).*/\1/p' <<< "${line}")"
      EFF="$(sed -n 's/.*EFF=\([0-9]*\).*/\1/p'     <<< "${line}")"
      OUT="$(sed -n 's/.*OUT=\([^ ]*\).*/\1/p'      <<< "${line}")"
      ;;
  esac
done < "${PY_OUT}"

# ── Resumo ────────────────────────────────────────────────────────────────────
echo ""
log_step 2 2 "Resultado"
log_ok "LAYOUT escolhido      : ${NI} × ${NJ}   (NIPROC × NJPROC = ${TOTAL} blocos)"
if [[ -n "${NMASK}" && "${NMASK}" -gt 0 ]]; then
  _save="$(awk "BEGIN{printf \"%.1f\", 100*${NMASK}/${TOTAL}}")"
  log_ok "Blocos 100% terra     : ${NMASK}  (economia de ${_save}% dos PETs)"
fi
log_ok "PETs efetivos (oceano): ${EFF}"
log_ok "mask_table gerado     : ${OUT}"

echo ""
log_sep
log_info "Como usar no MOM_input (e, se houver, no SIS_input):"
echo ""
printf "    LAYOUT = %s, %s\n" "${NI}" "${NJ}"
if [[ -n "${NMASK}" && "${NMASK}" -gt 0 ]]; then
  printf "    MASKTABLE = \"%s\"\n" "$(basename "${OUT}")"
fi
echo ""
log_info "Coloque o '${OUT##*/}' no diretório onde o FMS lê os inputs (ex.: INPUT/)."
if [[ -n "${EFF}" ]]; then
  log_info "No acoplador NUOPC/ESMF, o componente MOM6 deve receber ${EFF} PETs no petList."
fi
log_sep
