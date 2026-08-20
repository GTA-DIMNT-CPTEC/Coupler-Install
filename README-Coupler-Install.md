# Coupler-Install

Scripts de instalação do sistema acoplado **MONAN-A 2.0 × MOM6+SIS2**
(NUOPC-ESMF 8.9.1). Este repositório é **independente** do sistema acoplado: ele
baixa o `MONAN-Coupler` (com os modelos como submódulos) e compila tudo.

INPE / CGCT / DIMNT. GT Acoplamento de Modelos.

**Pré-requisitos:** `git` e o **ESMF 8.9.1** já instalado (com MOAB interno). O
caminho do ESMF é informado pela configuração de sítio (`sites/site-jaci.bash`).
Os modelos (MONAN-Model, MOM6-examples) chegam como **submódulos**; não é preciso
cloná-los à parte.

## Uso (um comando)

```bash
git clone --branch develop https://github.com/GTA-DIMNT-CPTEC/Coupler-Install.git
cd Coupler-Install
bash install.bash
```

O `install.bash` faz `git clone --recursive --branch develop` do
`MONAN-Coupler` (trazendo `MONAN-Model`, `MOM6-examples` e os submódulos
aninhados) e, em seguida, executa as três etapas de instalação.

Opções: `--coupler-root DIR`, `--branch BRANCH`, `--no-install` (só baixa),
`--from N` / `--only N` (repassadas ao `build.bash`). Veja todas com
`bash install.bash --help`.

Há também atalhos via `make` (camada fina sobre os scripts): `make` (= baixa +
instala), `make download`, `make build FROM=2`, `make check` (sanidade) e
`make help`. *Não confunda com o Makefile do `MONAN-Coupler`, que é o build real
do `bin/esmApp`; este aqui é só um lançador de comandos.*

Ao final, o executável fica em `<COUPLER_ROOT>/bin/esmApp`. Nas sessões
seguintes, a partir da raiz do sistema acoplado, basta recompilar/submeter sem o
instalador:

```bash
source run/setenv-gnu.bash      # define ESMFMKFILE, MPAS_DIR, MOM6_ROOT…
make                            # (re)compila bin/esmApp
bash run/run_esmApp.jaci -n 128 # submete via PBS (128 PETs)
```

## Estrutura

```
Coupler-Install/             ← scripts de instalação (standalone)
├── Makefile                 ← atalhos: make / make build / make check
├── install.bash             ← ★ baixa (git recursivo) e instala
├── build.bash               ← só as 3 etapas (já baixado)
├── include.bash             ← biblioteca de funções (sourced)
├── 1-monan.bash             ← etapa 1: MONAN-A 2.0
├── 2-mom.bash               ← etapa 2: MOM6+SIS2+FMS
├── 3-coupler.bash           ← etapa 3: linka bin/esmApp
├── sites/                   ← config por máquina
│   ├── site-jaci.bash       ← Jaci (padrão)
│   └── site-template.bash   ← esqueleto p/ nova máquina
├── templates/               ← templates de build
│   └── cray-gnu-monan.mk    ← template mkmf Cray/GNU
├── README.md
└── .gitignore
```

> **A documentação saiu deste repositório.** O antigo `docs/`, incluindo o
> `CHANGELOG.md`, passou para `MONAN-Coupler/docs/`. Os utilitários
> `domain-mom6.bash` e `gen-metis.bash` também saíram, para
> `MONAN-Coupler/tools/ocean/` e `MONAN-Coupler/tools/atmos/`.
> Neste repositório ficaram apenas os scripts de instalação.

`install.bash` = baixar + instalar (a partir do nada, um comando).
`build.bash` = só as 3 etapas de compilação, assumindo o sistema já baixado
(útil para recompilar sem mexer no git, ou retomar com `--from N`).

Os executáveis ficam na raiz (fáceis de invocar e se localizam entre si); os
dados de configuração ficam agrupados em `sites/` e `templates/`. Os scripts
encontram esses arquivos automaticamente; veja "Resolução de caminhos".

## Documentação

A documentação vive na árvore do `MONAN-Coupler`, em `docs/`. Ela foi movida
para lá porque descreve o **sistema acoplado**, e não o instalador: mantê-la
junto dos fontes que ela documenta evita que as duas versões divirjam.

| Documento (`<COUPLER_ROOT>/docs/`) | Assunto |
|:----------|:--------|
| `CHANGELOG.md` | Histórico de versões, no formato *Keep a Changelog* simplificado. Registra também o raciocínio por trás de decisões contraintuitivas, para que não sejam revertidas por engano. |
| `notas-standalone.md` | Notas de design da separação entre o instalador e o sistema acoplado: resolução de caminhos, preflight e o contrato entre os dois repositórios. |
| `domain-mom6.md` | Algoritmo do `tools/ocean/domain-mom6.bash`: soma de prefixos 2D, escore dos candidatos a `LAYOUT`, formato do `mask_table`, filtros de forma (`--min-tile`, `--max-aspect`) e armadilhas. |
| `mascara-cap-nuopc.md` | Por que um `mask_table` com `nmask > 0` é incompatível com o cap NUOPC atual do MOM6: representação densa contra esparsa no ESMF, o buraco no `DistGrid` e as duas rotas de correção. |
| `MULTINO-run_esmApp.md` | Execução em vários nós na Jaci: hardware do sítio, contabilidade de `ncpus`, topologia nas combinações de `coupling_mode` × `pet_layout`, tabela de filas e limites, planejador `plan-layout.py` e boas práticas. |
| `SMT-Jaci.md` | Caracterização do SMT nos nós de cálculo e medição do seu efeito sobre o acoplado: metodologia, resultados por componente, limitações de escopo e procedimento de reprodução. |

### Por onde começar

- **Instalando pela primeira vez:** este README basta. Consulte
  `docs/notas-standalone.md` apenas se algo na resolução de caminhos surpreender.
- **Preparando a decomposição do oceano:** `docs/domain-mom6.md` e, se aparecer
  SIGSEGV no conector `OCN-TO-MED`, `docs/mascara-cap-nuopc.md`.
- **Submetendo o acoplado na Jaci:** `docs/MULTINO-run_esmApp.md`.
- **Dimensionando PETs por nó:** `docs/SMT-Jaci.md` explica por que o padrão é
  256 e não 512, com a medição que sustenta a escolha.

## Onde mexer

| Quero…                              | Edite / use                                        |
|:------------------------------------|:---------------------------------------------------|
| Trocar ESMF, módulos, alvo de CPU   | `sites/site-jaci.bash`                             |
| Rodar em outra máquina              | copie `sites/site-template.bash` → `sites/site-X.bash`, ajuste e `export SITE_ENV=sites/site-X.bash` |
| Ajuste pontual sem editar arquivo   | `export VAR=valor` antes (tem prioridade sobre o sítio) |
| Outro template mkmf                 | `export MKMF_TEMPLATE_SRC=/caminho/template.mk`   |
| Outra raiz para o acoplador         | `--coupler-root DIR` ou `export COUPLER_ROOT=DIR` |
| Outro fork/branch dos modelos       | ajuste o `.gitmodules` do `MONAN-Coupler`         |
| Escolher o `LAYOUT` do MOM6+SIS2    | `<COUPLER_ROOT>/tools/ocean/domain-mom6.bash`; ver `docs/domain-mom6.md` |
| Submeter em vários nós              | `<COUPLER_ROOT>/run/run_esmApp.jaci`; ver `docs/MULTINO-run_esmApp.md` |
| Definir PETs por nó                 | padrão 256 (cores físicos); ver `docs/SMT-Jaci.md` |
| Gerar partições METIS do MPAS       | `<COUPLER_ROOT>/tools/atmos/gen-metis.bash`        |

## Resolução de caminhos

Como o instalador vive fora da árvore do acoplador, os scripts localizam o que
precisam por busca em vários locais (primeiro que existir vence):

- **Raiz do acoplador** (`COUPLER_ROOT`): ambiente → `./MONAN-Coupler`.
- **Sítio** (`site-jaci.bash`): `$SITE_ENV` → `sites/` → raiz → `install/` → `<COUPLER_ROOT>/run/setenv-site.bash` → `<COUPLER_ROOT>/install/` (legado).
- **Template** (`cray-gnu-monan.mk`): `$MKMF_TEMPLATE_SRC` → `templates/` → raiz → `install/templates/` → `<COUPLER_ROOT>/install/templates/`.

O `install.bash` confere **sítio e template antes do clone** (preflight),
falhando cedo e listando tudo que faltar de uma só vez. Também deixa uma cópia
da config de sítio em `<COUPLER_ROOT>/run/setenv-site.bash`, para que as
sessões de build (`source run/setenv-gnu.bash`) a encontrem sem o instalador,
de modo que o acoplador não precise de um diretório `install/`.

## Etapas isoladas

Com o sistema já baixado e `COUPLER_ROOT` exportado:

```bash
export COUPLER_ROOT=/caminho/MONAN-Coupler
bash build.bash --from 2          # retoma a partir da etapa 2   (= make build FROM=2)
bash 2-mom.bash --only-nuopc      # só o cap NUOPC do MOM6
bash 1-monan.bash --skip-init-atm # só o core atmosphere
```

Equivalentes diretos via `make`: `make monan`, `make mom`, `make coupler`.

## Depois de instalar

Com o `bin/esmApp` construído, o trabalho passa para a árvore do
`MONAN-Coupler`. O caminho mais curto até a primeira submissão:

```bash
cd <COUPLER_ROOT>
source run/setenv-gnu.bash

# 1. Decomposição do oceano (produto exato = PETs do OCN, sem mask_table)
bash tools/ocean/domain-mom6.bash --no-mask --pes 128

# 2. Planejar a topologia antes de editar a nuopc.input
python3 tools/coupler/plan-layout.py --atm 256 --ocn 128

# 3. Verificar pré-requisitos, partição METIS, select e limites da fila
bash run/run_esmApp.jaci -n 384 --check

# 4. Submeter
bash run/run_esmApp.jaci -n 384 -q pesqextra -w 02:00:00
```

Pontos que costumam surpreender na primeira vez, todos detalhados em
`docs/MULTINO-run_esmApp.md` (na árvore do `MONAN-Coupler`):

- O nó de cálculo anuncia `ncpus = 512`, mas o limite das filas é contado em
  **cores físicos**. O `select` pede no máximo 256 por nó, e a posse do nó
  inteiro vem de `place=scatter:excl`.
- No modo *concurrent*, a partição METIS é dimensionada por `atm_pet_count`, e
  não pelo total passado em `-n`.
- O `mask_table` do FMS com `nmask > 0` é incompatível com o cap NUOPC atual do
  MOM6. Use `--no-mask` no acoplado, conforme `docs/mascara-cap-nuopc.md`.
