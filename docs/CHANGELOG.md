# Changelog — Coupler-Install

Histórico de versões do instalador do sistema acoplado
**MONAN-A 2.0 × MOM6+SIS2** (NUOPC-ESMF 8.9.1).
INPE / CGCT / DIMNT — GT Acoplamento de Modelos.

O formato segue, de modo simplificado, *Keep a Changelog*; as datas são
aproximadas (iterações de desenvolvimento, Jun a Jul 2026).

## [Não lançado]

- **Correção (`mom_cap_MONAN.F90`): campos de importação sem estampilha de
  tempo.** No primeiro passo de acoplamento, o `CheckImportTolerant` comparava
  o `TimeStamp` de cada campo importado sem que ele tivesse sido definido: na
  RunSequence o OCN roda antes do conector MED para OCN, e o
  `NUOPC_GetTimestamp` do NUOPC 8.9.1 retorna `ESMF_SUCCESS` sem preencher o
  `ESMF_Time` (não existe o argumento `isValid=`). O resultado eram dois
  `ERROR` por campo (`ESMF_TimeLT` e `ESMF_TimeGT`, "Object Set or SetDefault
  method not called"), 28 linhas por execução com 14 campos importados. Sem
  efeito numérico, mas poluindo o log e mascarando erros reais. A
  `InitializeDataComplete` passa a estampilhar os campos de importação com
  `startTime`, como já fazia com os de exportação.
- **Correção (`domain-mom6.bash`): saída incoerente em `--no-mask`.** A coluna
  `PETs` da tabela de candidatos era sempre calculada como
  `NIPROC * NJPROC - Nmask`, mesmo em `--no-mask`, exibindo 121 para o `16x8`
  quando o resultado efetivo, informado três linhas abaixo, era 128. Agora a
  coluna respeita o modo, o rótulo da coluna de blocos secos alterna entre
  `MASCAR.` (eliminados) e `SECOS` (mantidos), e uma nota sob a tabela explicita
  que em `--no-mask` a contagem é informativa. Corrigido também o exemplo do
  `--help` e do cabeçalho, que apresentava `--target-eff` como receita para um
  run concorrente, justamente a configuração incompatível com o cap; o exemplo
  do acoplado passa a usar `--no-mask --pes N`, e o do `--target-eff` fica
  identificado como standalone. Colunas documentadas em `docs/domain-mom6.md`,
  seção 7.2.
- **Ressalva em aberto (`domain-mom6.bash`): convenção de fronteiras difere da
  do FMS.** O script distribui as sobras da divisão nos primeiros blocos; o
  `mpp_compute_extent` as distribui simetricamente (`Y-AXIS = 53 52 53` para
  158 pontos em 3 blocos, contra `53 53 52` do script). As fronteiras internas
  ficam deslocadas em um ponto e o conjunto de blocos secos pode divergir: em
  `15x9` o script marca `(8,8)` onde o FMS teria `(9,7)`. **No acoplado com
  `--no-mask` o efeito é nulo** (nenhum `mask_table` é lido); no uso standalone,
  porém, um bloco com oceano pode ser mascarado por engano. A distribuição
  simétrica está comprovada pelo log, mas o algoritmo exato ainda não foi
  conferido contra o fonte do `mpp_domains_mod`. Documentado em
  `docs/domain-mom6.md`, seção 5.
- **Documentação.** Novo `docs/mascara-cap-nuopc.md`, explicação didática e
  autocontida do problema da máscara: glossário PE/PET/DE, por que o split de
  comunicador não está envolvido, a diferença entre representação densa e
  esparsa no ESMF, como reconhecer o sintoma e as duas rotas de correção do
  cap, com a estimativa de ganho por número de PETs. A seção 2 do
  `docs/domain-mom6.md` foi reduzida a um resumo com ponteiro para ele.
- **Correção (incidente do LAYOUT 43x3, 22/07/2026).** Run de 256 PETs em modo
  concorrente (128 ATM + 128 OCN) abortava com SIGSEGV no PET 171 logo após
  `COMPLETED MOM INITIALIZATION`. Causa: o `mask_table` gerado para
  `LAYOUT = 43, 3` remove o bloco `(1,3)` da decomposição, e o cap NUOPC do
  MOM6 monta o `deBlockList` do `ESMF_Grid` apenas com os domínios dos PETs
  vivos. O espaço de índices `[1..180] x [1..158]` fica com um buraco de
  5 x 53 células; `ESMF_DistGridCreate` e `ESMF_GridCreate` aceitam em
  silêncio, e a falha só emerge no conector `OCN-TO-MED`, em
  `ESMF_GridToMesh`: `ESMCI_Mesh.C, line:1786: Bad processor number!`.
  - Configuração corrigida: `LAYOUT = 16, 8` (produto exato = 128 PETs do OCN)
    com `MASKTABLE` comentado em `MOM_input` e `SIS_input`.
  - `domain-mom6.bash`: **filtro de forma** com `--min-tile` (padrão 9, que é
    `2*NIHALO+1`, o halo do domínio `MOM_MOSAIC`) e `--max-aspect` (padrão
    4,0). O `43x3` tinha blocos de 4,2 pontos, menores que o próprio halo, e
    passava sem qualquer alerta.
  - `domain-mom6.bash`: a varredura do `--target-eff` deixa de aceitar o
    primeiro `EFF` que bate. O novo modo `scan` do awk devolve todos os pares
    de fatores aprovados no filtro para cada nº de blocos, e vence o de melhor
    forma em **toda** a faixa. Na grade 180 x 158, o alvo 128 passa a resolver
    para `15x9` (blocos de 12,0 x 17,6; nmask = 7) em vez de `43x3`.
  - `domain-mom6.bash`: novo `--no-mask`, que escolhe o melhor `LAYOUT` com
    produto exatamente igual aos PETs do oceano e não gera `mask_table`,
    comentando com `!` uma diretiva `MASKTABLE` remanescente nos arquivos de
    entrada. É o único modo compatível com o cap NUOPC atual.
  - `domain-mom6.bash`: aviso explícito sempre que um `mask_table` com
    `nmask > 0` é produzido, indicando que ele serve ao MOM6+SIS2 standalone,
    não ao acoplado.
  - Pendência em `mom_cap_MONAN.F90`: para suportar `mask_table`, o
    `deBlockList` precisa cobrir todo o espaço de índices, com DEs adicionais
    para os blocos mascarados mapeados a PETs existentes via `petMap`
    (o `ESMF_DELayout` aceita mais de um DE por PET).
- **Novo utilitário (`domain-mom6.bash`): decomposição de domínio do MOM6+SIS2.**
  Calcula um `LAYOUT` (NIPROC, NJPROC) equilibrado e gera o `mask_table` do FMS,
  eliminando os blocos 100% terra. Os PETs efetivos passam a ser
  `EFF = NIPROC * NJPROC - Nmask`, valor que deve casar com os PETs que o
  oceano realmente recebe (o total do run em `sequential`; apenas
  `ocn_pet_count` em `concurrent`), evitando o erro fatal
  `fms2_io(parse_mask_table_2d): mpp_npes() .NE. layout(1)*layout(2) - nmask`.
  - Três modos: `--pes N` (fatora N e ordena os candidatos por razão de aspecto,
    divisão exata e tamanho mínimo de bloco), `--layout NI,NJ` (explícito) e
    `--target-eff N` (varre `--pes N..N+search-range` até obter `EFF` exato,
    já que o nº de blocos mascarados depende da **forma** do `LAYOUT`, não só
    do produto).
  - Implementação **100% shell**: `ncdump` (módulo `cray-netcdf`) e `awk`
    (POSIX), sem dependência de Python, numpy ou netCDF4. Não depende do
    `COUPLER_ROOT` nem do ESMF: opera apenas sobre a topografia.
  - Núcleo: **soma de prefixos 2D** (imagem integral) do campo binário de
    oceano, construída uma única vez; a contagem de oceano em cada bloco
    candidato custa O(1), o que viabiliza a varredura do `--target-eff`.
  - Detecção automática da variável (`depth`, `D`, `wet`, `mask`, ou
    `--depth-var`) e das dimensões pelas duas últimas da declaração (robusto a
    `ny,nx` / `lat,lon` / `grid_y,grid_x`). Limiar de oceano por `--min-depth`
    para profundidade e 0,5 para máscara.
  - Integração opcional com o experimento: `--input-dir` copia o `mask_table`
    para `INPUT/`; `--mom-input`/`--sis-input` reescrevem `LAYOUT` e
    `MASKTABLE` com backup `.bak.<timestamp>`; `--dry-run` suprime cópia e
    edição (o `mask_table`, sendo o próprio resultado do cálculo, ainda é
    gravado). Avisos para blocos pequenos, divisão inexata e `Nmask = 0`.
  - Reaproveita o `include.bash` do instalador para o log padronizado, com
    *fallback* próprio quando ausente.
- **Documentação.** Novo `docs/domain-mom6.md` (algoritmo detalhado: soma de
  prefixos, escore dos candidatos, formato do `mask_table`, custo e armadilhas)
  e `README.md` com a subseção "Decomposição de domínio do MOM6+SIS2", logo
  após as partições METIS do MPAS, mais as entradas correspondentes na árvore
  de estrutura e na tabela "Onde mexer".

- **Correção (ESMF externo no MONAN-A).** A etapa 1 falhava ao compilar
  `mpas_timekeeping.F` (`timeStringISOFrac`/`h=` não reconhecidos) porque o
  `-DMPAS_EXTERNAL_ESMF_LIB` resolvia `use ESMF` para o *stub* interno do MPAS
  (`src/external/esmf_time_f90`) em vez do ESMF 8.9.1 real. O Makefile do
  MONAN-Model só injeta o ESMF real quando `ESMF_MOD` e `ESMF_LIBDIR` estão no
  ambiente — e os scripts não as exportavam.
  - `sites/site-jaci.bash` e `sites/site-template.bash`: passam a **derivar e
    exportar** `ESMF_MOD` (dir do `esmf.mod`, via `ESMF_F90COMPILEPATHS`) e
    `ESMF_LIBDIR` (dir da `libesmf`, via `-L` de `ESMF_F90LINKPATHS`, com
    *fallback* no diretório do próprio `esmf.mk`) — fonte única, em bloco
    auto-contido (vale também para `source run/setenv-gnu.bash`). Não se usa a
    variável `ESMF_LIBDIR` do `esmf.mk`: ela não existe em todo build do ESMF.
  - `1-monan.bash`: deixa de recalcular; apenas **verifica** as variáveis
    (`check_var`) e aborta com mensagem clara se faltarem.
  - `2-mom.bash`: **consome** o `ESMF_LIBDIR` do sítio para o `LD_LIBRARY_PATH`;
    `ESMF_APPSDIR` passa a ser tolerante a vazio (apenas avisa). O helper
    `_esmf_mk` é mantido para as flags canônicas do cap NUOPC (Passo 3).
- **Correção (toolchain GNU na etapa 3 e no rebuild manual).** O `make all` do
  acoplador falhava com o `ftn` acionando o compilador Cray (CCE) e rejeitando
  os flags GNU do Makefile (`-mcmodel=small`, `-ffree-line-length-none`,
  `-fallow-argument-mismatch`, …). Causa: o `run/setenv-gnu.bash` só definia
  caminhos (não carregava módulos) e fazia `unset MODULES_MONAN`; como cada
  etapa roda em subprocesso, o `PrgEnv-gnu` das etapas 1-2 não persistia.
  - `run/setenv-gnu.bash` (repo `MONAN-Coupler`): passa a **carregar os módulos**
    (`module purge` + `MODULES_MONAN` do sítio — PrgEnv-gnu + hdf5 + netcdf +
    parallel-netcdf + METIS) logo após o *source* da config, antes do
    `PNETCDF_DIR`. Como é *sourced*, os módulos persistem na sessão — isso conserta
    também o **rebuild manual** do README (`source run/setenv-gnu.bash && make`).
    Opt-out: `export SETENV_NO_MODULES=1`. (Entregue como `setenv-gnu.patch`.)
  - `3-coupler.bash`: **delega** os módulos ao setenv (sem `load_modules`
    redundante) e adiciona uma **guarda de toolchain** — confere `PE_ENV=GNU`
    (var padrão do Cray PE) após o *source* e aborta cedo, com mensagem clara, se
    o `PrgEnv-gnu` não estiver ativo (ex.: setenv-gnu.bash desatualizado).
- Organização: `docs/` (changelog + notas), `sites/site-template.bash`
  (esqueleto para nova máquina) e `Makefile` fino (atalhos: `make`,
  `make download`, `make build`, `make check`, `make help`).
- Passos renomeados (nomes mais curtos, sem "install" redundante):
  `1-install-monan.bash`→`1-monan.bash`, `2-install-mom.bash`→`2-mom.bash`,
  `3-install-coupler.bash`→`3-coupler.bash`.

## v14.15 — Jun 2026

- Repositório do instalador renomeado de `MONAN-Coupler-install` para
  **`Coupler-Install`**.
- Configuração de sítio de sessão movida para `<COUPLER_ROOT>/run/setenv-site.bash`
  (remove a necessidade de um diretório `install/` na árvore do acoplador).
- `setenv-gnu.bash` endurecido: refaz a busca da config quando `SITE_ENV`
  aponta para arquivo inexistente (evita herdar valor obsoleto de um `source`
  anterior que falhou).

## v14.14 — Jun 2026

- Renomeação dos pontos de entrada: `bootstrap.bash`→**`install.bash`**
  (baixa + instala) e `install-all.bash`→**`build.bash`** (só as 3 etapas).
- Biblioteca de funções `install-libs.bash`→**`include.bash`** (é *sourced*).
- Layout organizado: `sites/` (configs por máquina) e `templates/` (mkmf).

## v14.13 — Jun 2026

- Instalador separado em repositório próprio, independente do sistema acoplado.
- `MONAN-Model` e `MOM6-examples` passam a ser **submódulos** do `MONAN-Coupler`
  (clone recursivo na branch `develop`).
- `install.bash` faz o download recursivo do sistema e dispara a instalação.
- Resolvedores tolerantes a layout (`resolve_coupler_root`, `resolve_site_env`,
  `resolve_mkmf_template`) e busca de submódulos (`ensure_model_tree`).

## Anterior — Jun 2026

- Reestruturação de caminhos para o layout multi-modelo
  (`models/atmos/MONAN-Model`, `models/ocean/MOM6-examples`).
- Pipeline de instalação em três etapas (MONAN-A, MOM6+SIS2, acoplador).
