# Changelog — Coupler-Install

Histórico de versões do instalador do sistema acoplado
**MONAN-A 2.0 × MOM6+SIS2** (NUOPC-ESMF 8.9.1).
INPE / CGCT / DIMNT — GT Acoplamento de Modelos.

O formato segue, de modo simplificado, *Keep a Changelog*; as datas são
aproximadas (iterações de desenvolvimento, Jun 2026).

## [Não lançado]

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
