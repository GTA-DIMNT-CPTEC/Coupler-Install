# Changelog — Coupler-Install

Histórico de versões do instalador do sistema acoplado
**MONAN-A 2.0 × MOM6+SIS2** (NUOPC-ESMF 8.9.1).
INPE / CGCT / DIMNT — GT Acoplamento de Modelos.

O formato segue, de modo simplificado, *Keep a Changelog*; as datas são
aproximadas (iterações de desenvolvimento, Jun 2026).

## [Não lançado]

- **Funcionalidade (`log_kind` configurável — `&nuopc_driver`).** O nível de
  log ESMF por PET passou a ser escolhido em `nuopc.input`, sem recompilar:
  `log_kind = 'multi'` (padrão, grava tudo incl. INFO — necessário para
  `test-concurrent.bash` e `analisa_balanceamento_pets.py`) ou
  `log_kind = 'multi_on_error'` (log só materializado em caso de erro — mais
  rápido, porém uma execução bem-sucedida pode deixar
  `logs/PET*.esmApp.log` incompleto/ausente, dado o `chdir` de volta ao
  diretório do experimento já ter ocorrido quando o log seria aberto).
  - `mpas_cap_config.F90`: novo campo `cfg_log_kind` no grupo
    `&nuopc_driver` (leitura, validação `multi|multi_on_error`, aviso
    explícito do risco acima quando `multi_on_error` é escolhido, impressão
    em `config_print`).
  - `esmApp.F90`: novo `type(ESMF_LogKind_Flag) :: esmfLogKind`, escolhido a
    partir de `cfg_log_kind` e passado a `ESMF_Initialize` (antes, o valor
    `ESMF_LOGKIND_MULTI` era fixo no código-fonte).
  - `nuopc.input`: `log_kind` documentado e adicionado ao grupo
    `&nuopc_driver`.

- **Funcionalidade (análise de balanceamento — `analisa_balanceamento_pets.py`).**
  Novo script Python que lê `logs/PET*.esmApp.log`, soma o tempo total de cada
  componente (MPAS/OCN/MED) — nunca "contagem de chamadas Run × passos", já
  que o MOM6 subcicla internamente (observado entre ~2 e ~301 chamadas `Run`
  por passo, a depender da configuração) — e sugere `atm_pet_count`/
  `ocn_pet_count` balanceados, assumindo escalonamento aproximadamente linear.
  Detecta a partição de PETs pela linha `ESM: modo CONCURRENT — ATM=PET[...]`
  do log (nível INFO) ou, na ausência dela (comum sob
  `ESMF_LOGKIND_Multi_On_Error`, que suprime INFO), infere os grupos a partir
  de quais PETs reportam atividade de MPAS/OCN. Também funciona sobre logs de
  execução sequencial, extrapolando os custos medidos para uma sugestão
  inicial. Exporta detalhe por chamada (`--csv-out`), resumo de máquina
  (`--json-out`, reutilizável como baseline via `--baseline-json`) e um
  gráfico comparativo por PET (`--plot-out`). Validado com dados sintéticos
  (incluindo log truncado/deadlock, ausência de anúncio de partição, e modo
  sequencial) e com os logs reais da execução concorrente validada.

- **Correção (deadlock real do modo concurrent — VM global na leitura OISST/JRA).**
  Diagnóstico do travamento em `concurrent × Fase 2` (4 ATM / 4 OCN): a
  inicialização parava no `DataInitialize` da cap do MOM6, dentro de
  `ReadOcnFieldInterp` (`docn_cap_netcdf.F90`), reusada por
  `set_si_ifrac_from_file` para ler o gelo do OISST. A rotina obtinha a VM com
  `ESMF_VMGetGlobal` (todos os 8 PETs) e fazia `ESMF_VMBroadcast` coletivo com
  `rootPet=0`; em concurrent o OCN roda só nos PETs 4–7, então apenas eles
  entravam no broadcast (e o PET0 raiz é do ATM) → coletivo de 8 nunca fechava
  → deadlock (job cancelado por walltime). Correção: usar a VM do COMPONENTE
  via `ESMF_GridCompGet(gcomp, vm=vm)` — em sequential a VM do componente é
  igual à global, mantendo o comportamento; em concurrent, o broadcast passa a
  ser sobre os PETs do componente, com raiz local. Aplicado às três rotinas de
  leitura de dado que tinham o mesmo padrão:
  - `docn_cap_netcdf.F90::ReadOcnFieldInterp` (ativa — a que travava);
  - `DOCN_cap.F90::ReadOcnFieldInterp` (DOCN Fase 1 concorrente);
  - `DATM_cap.F90::ReadJRAFieldInterp` (teste DATM concorrente).
  Não alterados: `MED_cap.F90::fill_ifrac_from_oisst` (o mediador roda em todos
  os PETs, então a VM global coincide com a do componente) e `esmApp.F90` (o
  programa principal legitimamente usa a VM global).

- **Funcionalidade (particionamento de PETs — modos sequential/concurrent).**
  Novo grupo `&nuopc_petlayout` em `nuopc.input` controla a distribuição dos
  PETs (ranks MPI) entre os componentes, permitindo execução **sequencial**
  (padrão, retrocompatível — todos os componentes em todos os PETs) ou
  **concorrente** (ATM e OCN em blocos disjuntos de PETs, avançando em
  paralelo; MED em todos).
  - `mpas_cap_config.F90`: leitura e validação de `coupling_mode`,
    `atm_pet_count`, `ocn_pet_count` (grupo `&nuopc_petlayout`); helper
    `str_lower` para tolerância a maiúsculas; impressão em `config_print`.
  - `esm.F90` (`SetModelServices`): substitui o `petList` único por
    `atmPetList`/`ocnPetList`/`medPetList`; auto-split (metade/metade quando
    contagens = 0) e validação `nAtm + nOcn == petCount`.
  - `esm.F90` (`SetRunSequence`): duas novas RunSequences concorrentes
    (Fase 1 DOCN e Fase 2 MOM6) com `MPAS`/`OCN` consecutivos em PETs
    disjuntos (execução paralela) e lag de 1 `dt_coupling` no mediador.
  - `nuopc.input`: grupo `&nuopc_petlayout` documentado (Grupo 7).
  - `README.md`: seção "Modos de execução (particionamento de PETs)".
  - `run/gen-metis.bash`: gerador de partições METIS do MPAS
    (`x1.NNNNN.graph.info.part.N`). Lê malha e modo da `nuopc.input` e gera o
    que falta: `.part.<NPES>` (sequential/pré-check) e, em `concurrent`,
    também `.part.<atm_pet_count>` (usado de fato pelo MPAS). Carrega
    `METIS/5.1.0` se preciso; pula partições já existentes; `--dry-run`,
    `--parts`, `--force`.
  - `run/test-concurrent.bash`: smoke test do modo concorrente — verifica
    partição, inicialização dos três componentes e avanço do 1º passo sem
    deadlock nos coletivos MPI (encerra ao 1º NetCDF de diagnóstico do
    mediador; *watchdog* de estagnação detecta hang). Não altera o
    `nuopc.input` (usa `NUOPC_INPUT` + diretórios isolados). Submissão PBS no
    mesmo padrão dual-mode do `run_esmApp.jaci` (login → `qsub`; dentro do job
    → módulos + `setenv` + PALS `mpiexec`); `COUPLER_ROOT` autodeduzido,
    recursos PBS (`select`, fila, conta, cpus/nó) parametrizáveis; `--local`
    para execução direta em sessão interativa.
  - `run/run_esmApp.jaci`: pré-check agora é **ciente do layout de PETs**.
    Em `concurrent`, exige/gera `x1.NNNNN.graph.info.part.<atm_pet_count>`
    (o que o MPAS de fato usa) em vez de `.part.<NPES>`; em `sequential`
    mantém `.part.<NPES>`. A checagem é feita pelo glob do próprio arquivo de
    partição (robusta à ausência do graph base `x1.*.graph.info`, que só é
    exigido para *gerar*). Gera a partição faltante automaticamente (via
    `gen-metis.bash`). Novo *guard*: em `concurrent`, aborta o pré-check se
    `-n ≠ atm_pet_count + ocn_pet_count`. Corrigido bug latente do
    `_nuopc_get` (o `s/.*=.../` guloso lia o valor errado quando o comentário
    do campo continha `=`, ex.: `atm_pet_count = 4 ! (0 = auto)`): o
    comentário passa a ser removido antes da extração.
  - Os caps não mudam: todos já extraem o comunicador da VM local do
    componente (`ESMF_GridCompGet`/`ESMF_VMGetCurrent`) e reduzem sobre esse
    comunicador, funcionando nos dois modos sem alteração.
  - **Blindagem contra deadlock (modo concurrent).** Removidos os *fallbacks*
    silenciosos para `MPI_COMM_WORLD` que, no modo concorrente (componente em
    subconjunto de PETs), causariam mismatch coletivo / deadlock nos
    `MPI_Allreduce`:
    - `MED_cap.F90` (`InitializeRealize`): em erro de `ESMF_VMGetCurrent`/
      `ESMF_VMGet`, aborta limpo via `ESMF_LogFoundError`+`return` em vez de
      atribuir `med_mpi_comm = MPI_COMM_WORLD`.
    - `mpas_cap_methods.F90` (`state_set_field_1d`, gather Voronoi): idem —
      `ESMF_LogWrite(…ERROR)`+`return` em vez de `mpi_comm_use = MPI_COMM_WORLD`.
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
