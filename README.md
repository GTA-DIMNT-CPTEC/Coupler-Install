# Coupler-Install

Scripts de instalação do sistema acoplado **MONAN-A 2.0 × MOM6+SIS2**
(NUOPC-ESMF 8.9.1). Este repositório é **independente** do sistema acoplado: ele
baixa o `MONAN-Coupler` (com os modelos como submódulos) e compila tudo.

INPE / CGCT / DIMNT — GT Acoplamento de Modelos.

**Pré-requisitos:** `git` e o **ESMF 8.9.1** já instalado (com MOAB interno) — o
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

## Modos de execução (particionamento de PETs)

O particionamento dos PETs (ranks MPI) entre os componentes é controlado pelo
grupo `&nuopc_petlayout` em `nuopc.input`:

- **`sequential`** (padrão): `MPAS`, `MED` e `OCN` rodam em **todos os PETs**,
  um componente de cada vez. Throughput máximo por componente; atmosfera e
  oceano não se sobrepõem no tempo. Retrocompatível com versões anteriores.
- **`concurrent`**: `ATM` e `OCN` ocupam **blocos disjuntos de PETs** e avançam
  **em paralelo** (wall-clock); o `MED` permanece em todos os PETs. O tempo por
  passo passa de `t_ATM + t_OCN` para `max(t_ATM, t_OCN)`.

```fortran
! Exemplo concurrent com 128 PETs (nuopc.input):
&nuopc_petlayout
  coupling_mode = 'concurrent'
  atm_pet_count = 88     ! MPAS  → PET 0..87
  ocn_pet_count = 40     ! MOM6  → PET 88..127  (soma = 128 = -n)
/
```

Em `concurrent`, `atm_pet_count + ocn_pet_count` deve ser igual ao total de PETs
(`-n`); com `0` em um dos dois, o outro é completado automaticamente. Dimensione
a razão ATM:OCN pelo custo relativo (o MPAS costuma dominar — ponto de partida
~2:1 a ~3:1) e rebalanceie medindo o tempo de cada componente em
`logs/PET*.esmApp.log`. O modo funciona nas Fases 1 (DOCN) e 2 (MOM6); o ganho é
maior na Fase 2.

### Partições METIS do MPAS (`gen-metis.bash`)

O MPAS decompõe a malha por METIS e lê `x1.NNNNN.graph.info.part.N`, onde **N é o
número de tarefas MPI no comunicador do MPAS** — não o total do job. Em
`sequential`, `N = NPES` (o `-n`); em `concurrent`, `N = atm_pet_count`. O MOM6
não usa METIS: ele decompõe a própria grade lógica por *layout*, tratado na
subseção seguinte (`domain-mom6.bash`).

O script `run/gen-metis.bash` gera as partições necessárias lendo malha e modo da
`nuopc.input`:

```bash
cd /…/exp1
gen-metis.bash -n 8                 # deriva o que falta da nuopc.input
gen-metis.bash --parts "8 4 16"     # gera exatamente esses N
gen-metis.bash -n 8 --dry-run       # mostra o que faria, sem gerar
```

> Pegadinha do modo concorrente: o `run_esmApp.jaci` faz o pré-check por `-n`
> (pede `.part.<NPES>`), mas o MPAS em `concurrent` usa `.part.<atm_pet_count>`.
> Por isso, nesse modo, o `gen-metis.bash` gera **os dois** — ex.: `-n 8` com
> `atm_pet_count=4` gera `.part.8` (pré-check) e `.part.4` (MPAS em execução).

Desde a v13.0 o `run_esmApp.jaci` já resolve isso sozinho: o pré-check tornou-se
ciente do layout — em `concurrent` ele exige/gera diretamente
`.part.<atm_pet_count>` (o número que o MPAS realmente usa), chama o
`gen-metis.bash` para gerar a partição que faltar, e **aborta** se
`-n ≠ atm_pet_count + ocn_pet_count`. Assim, o fluxo volta a ser um único
`run_esmApp.jaci -n N`. O `gen-metis.bash` continua útil para gerar partições
avulsas (estudos de escalabilidade) ou fora do `run_esmApp.jaci`.

### Decomposição de domínio do MOM6+SIS2 (`domain-mom6.bash`)

É o análogo do `gen-metis.bash` para o lado oceânico. O MOM6 fatia a grade
global em `NIPROC x NJPROC` blocos (`LAYOUT`), um PE por bloco, e o produto
`NIPROC * NJPROC` precisa casar com os PETs que o oceano recebe: o total do run
(`-n`) em `sequential`, apenas `ocn_pet_count` em `concurrent`. Se não bater, o
FMS aborta com:

```
fms2_io(parse_mask_table_2d): mpp_npes() .NE. layout(1)*layout(2) - nmask
```

O `domain-mom6.bash` escolhe o `LAYOUT` equilibrado a partir da topografia e,
opcionalmente, atualiza `MOM_input` e `SIS_input`. É 100% shell (`ncdump` do
módulo `cray-netcdf` mais `awk`), não usa Python e não depende do
`COUPLER_ROOT` nem do ESMF, podendo ser executado de qualquer diretório.

```bash
module load cray-netcdf
cd /…/exp1

# Uso normal no acoplado: LAYOUT com produto exato = PETs do OCN.
# Casa com o exemplo concorrente acima (ocn_pet_count = 40).
bash domain-mom6.bash --topog INPUT/ocean_topog.nc --no-mask --pes 40 \
     --mom-input MOM_input --sis-input SIS_input

# Inspecionar sem tocar nos arquivos de configuração
bash domain-mom6.bash --topog INPUT/ocean_topog.nc --no-mask --pes 40 --dry-run

# LAYOUT explícito
bash domain-mom6.bash --topog INPUT/ocean_topog.nc --layout 8,5
```

O script filtra a forma dos blocos: `--min-tile` (padrão 9 pontos, que é
`2*NIHALO+1`, o halo do domínio `MOM_MOSAIC`) e `--max-aspect` (padrão 4,0).
Blocos menores que o halo fazem o FMS ler além do domínio do vizinho.

> **`mask_table` não funciona no acoplado.** O cap NUOPC do MOM6 monta o
> `ESMF_Grid` com um `deBlockList` formado só pelos blocos que têm PET. Blocos
> mascarados deixam buracos no espaço de índices; o `ESMF_DistGridCreate` aceita
> em silêncio e a falha só aparece no conector `OCN-TO-MED`, em
> `ESMF_GridToMesh`, com `Bad processor number!` seguido de SIGSEGV. Por isso a
> opção `--no-mask` é o caminho padrão aqui, e o modo `--target-eff` (que busca
> um `EFF` alvo descontando a máscara) fica reservado ao MOM6+SIS2 standalone.
> Explicação completa, com as duas rotas de correção do cap, em
> `docs/mascara-cap-nuopc.md`.

Com `--no-mask` os blocos 100% terra continuam existindo e recebem PET, o que
custa pouco por não haver oceano neles. Na grade 180 x 158 com 128 PETs, o
resultado é `LAYOUT = 16, 8` com 7 blocos secos, e o script comenta com `!` uma
diretiva `MASKTABLE` remanescente nos arquivos de entrada.

O `LAYOUT` deve ser idêntico em `MOM_input` e `SIS_input` (o script atualiza
ambos, com backup `.bak.<timestamp>`). Regenere-o sempre que mudar a topografia,
a resolução ou o número de PETs do oceano. Para gerar um `mask_table` destinado
ao MOM6+SIS2 standalone, veja antes a ressalva sobre a convenção de fronteiras
em `docs/domain-mom6.md`, seção 5. Detalhes do algoritmo (soma de
prefixos 2D, escore dos candidatos, formato do `mask_table`) em
`docs/domain-mom6.md`; todas as opções em `bash domain-mom6.bash --help`.

### Smoke test do modo concorrente

O script `run/test-concurrent.bash` faz uma verificação rápida de que o modo
concorrente reparte os PETs, inicializa os três componentes e **avança o primeiro
passo de acoplamento sem travar** nos `MPI_Allreduce` coletivos (o cenário de
deadlock). Ele não altera o seu `nuopc.input` — gera uma cópia de teste injetada
via `NUOPC_INPUT` e usa diretórios de log/diagnóstico isolados.

Segue o **mesmo padrão dual-mode do `run_esmApp.jaci`** (detecção por
`PBS_O_WORKDIR`): no nó de login gera um `.pbs` e faz `qsub`; dentro do job
carrega os módulos, faz `source` do `setenv` e roda o teste (lançador PALS
`mpiexec` + watchdog). `COUPLER_ROOT` é autodeduzido; o executável vem de
`<COUPLER_ROOT>/bin/esmApp` e o experimento é o diretório atual.

```bash
export PATH="$PATH:/…/MONAN-Coupler/run"          # uma vez

cd /…/exp1                                         # entradas do run
test-concurrent.bash -n 8                          # submete via qsub (4 ATM / 4 OCN)
test-concurrent.bash -n 128 --atm 88 --ocn 40 -w 00:20:00
test-concurrent.bash -n 8 --local                  # execução direta (sessão interativa qsub -I)
test-concurrent.bash -n 8 --dry-run                # gera o .pbs e mostra o comando, sem submeter
```

Diretivas PBS específicas do sítio são sobrescrevíveis: `--queue`, `--account`,
`--ncpus-node` (padrão 128, para calcular `select`) e `--select` (linha inteira).
Ajuste-as conforme a política da Jaci / o seu `run_esmApp.jaci`.

O teste encerra assim que o mediador grava o primeiro NetCDF de diagnóstico
(prova de que os coletivos do passo 1 passaram). Se nenhum arquivo surgir dentro
das janelas de estagnação/tempo-limite (processo vivo, parado num coletivo), o
veredito é *provável deadlock*, com o *tail* dos logs de cada PET. Veja
`test-concurrent.bash --help` para todas as opções.

### Calibração da partição (`analisa_balanceamento_pets.py`)

Depois de uma execução concorrente (ou sequencial, como baseline), o script
`run/analisa_balanceamento_pets.py` lê os `logs/PET*.esmApp.log`, mede o tempo
de parede de cada componente e sugere `atm_pet_count`/`ocn_pet_count`
balanceados para a próxima rodada:

```bash
python3 run/analisa_balanceamento_pets.py --logdir logs

python3 run/analisa_balanceamento_pets.py --logdir logs \
  --csv-out tempos.csv --json-out resumo.json --plot-out balanceamento.png

python3 run/analisa_balanceamento_pets.py --logdir logs --target-pets 128
python3 run/analisa_balanceamento_pets.py --logdir logs --baseline-json resumo_anterior.json
```

Pontos importantes de como ele mede:

- **Soma o tempo total de cada componente**, nunca "conta de chamadas × passos"
  — o MOM6 subcicla internamente (já observamos de ~2 a ~301 chamadas `Run`
  internas por passo de acoplamento, a depender da configuração), enquanto o
  MPAS costuma ter uma chamada por passo. O nº de passos usado na divisão vem
  de `--steps`, ou é autodetectado em `esmApp_run.log`.
- **Detecta a partição de PETs de duas formas**: lendo a linha
  `ESM: modo CONCURRENT — ATM=PET[...] OCN=PET[...]` do log (nível INFO) ou,
  se ausente — caso comum ao usar `ESMF_LOGKIND_Multi_On_Error` em produção,
  que suprime mensagens INFO —, **infere** os grupos a partir de quais PETs
  reportam atividade de MPAS/OCN.
- **Sugestão de partição**: assume escalonamento aproximadamente linear
  (`tempo ≈ trabalho / nº PETs`) para estimar `atm_pet_count`/`ocn_pet_count`
  que equilibrem `t_ATM` e `t_OCN` — uma aproximação de primeira ordem, a
  validar com uma nova execução concorrente real, não um resultado exato.
- Também funciona sobre logs de uma execução **sequencial**, extrapolando os
  custos medidos para sugerir uma partição inicial antes do primeiro teste
  concorrente.

Veja `analisa_balanceamento_pets.py --help` para todas as opções.

### Nível de log ESMF (`log_kind`)

O grupo `&nuopc_driver` do `nuopc.input` controla o nível de detalhe do log
ESMF por PET (`logs/PET*.esmApp.log`) sem precisar recompilar:

```fortran
&nuopc_driver
  ...
  log_kind = 'multi'  ! 'multi' (calibração) | 'multi_on_error' (produção)
/
```

- **`multi`** (padrão): grava todas as mensagens, inclusive INFO — é o que
  `test-concurrent.bash` e `analisa_balanceamento_pets.py` precisam para medir
  tempo por componente/passo. Use durante calibração/testes.
- **`multi_on_error`**: log só é materializado em caso de erro — mais rápido
  e com arquivos bem menores. **Atenção**: numa execução *bem-sucedida*,
  `logs/PET*.esmApp.log` pode ficar incompleto ou ausente (o log ESMF só é
  aberto no momento do erro, quando o `chdir` de volta ao diretório do
  experimento já ocorreu). Reserve para produção já calibrada, quando não for
  mais preciso medir tempo por passo.

## Estrutura

```
Coupler-Install/             ← scripts de instalação (standalone)
├── Makefile                 ← atalhos: make / make build / make check
├── install.bash             ← ★ baixa (git recursivo) e instala
├── build.bash               ← só as 3 etapas (já baixado)
├── include.bash             ← biblioteca de funções (sourced)
├── 1-monan.bash             ← etapa 1 — MONAN-A 2.0
├── 2-mom.bash               ← etapa 2 — MOM6+SIS2+FMS
├── 3-coupler.bash           ← etapa 3 — linka bin/esmApp
├── domain-mom6.bash         ← utilitário: LAYOUT + mask_table do MOM6+SIS2
├── sites/                   ← config por máquina
│   ├── site-jaci.bash       ← Jaci (padrão)
│   └── site-template.bash   ← esqueleto p/ nova máquina
├── templates/               ← templates de build
│   └── cray-gnu-monan.mk    ← template mkmf Cray/GNU
├── docs/                    ← documentação
│   ├── CHANGELOG.md         ← histórico do instalador
│   ├── domain-mom6.md       ← algoritmo da decomposição de domínio
│   ├── mascara-cap-nuopc.md ← por que mask_table falha no acoplado
│   └── notas-standalone.md  ← notas de design (separação)
├── README.md
└── .gitignore
```

`install.bash` = baixar + instalar (a partir do nada, um comando).
`build.bash` = só as 3 etapas de compilação, assumindo o sistema já baixado
(útil para recompilar sem mexer no git, ou retomar com `--from N`).

Os executáveis ficam na raiz (fáceis de invocar e se localizam entre si); os
dados de configuração ficam agrupados em `sites/` e `templates/`. Os scripts
encontram esses arquivos automaticamente — veja "Resolução de caminhos".

## Onde mexer

| Quero…                              | Edite / use                                        |
|:------------------------------------|:---------------------------------------------------|
| Trocar ESMF, módulos, alvo de CPU   | `sites/site-jaci.bash`                             |
| Rodar em outra máquina              | copie `sites/site-template.bash` → `sites/site-X.bash`, ajuste e `export SITE_ENV=sites/site-X.bash` |
| Ajuste pontual sem editar arquivo   | `export VAR=valor` antes (tem prioridade sobre o sítio) |
| Outro template mkmf                 | `export MKMF_TEMPLATE_SRC=/caminho/template.mk`   |
| Outra raiz para o acoplador         | `--coupler-root DIR` ou `export COUPLER_ROOT=DIR` |
| Outro fork/branch dos modelos       | ajuste o `.gitmodules` do `MONAN-Coupler`         |
| Mudar o nº de PETs do oceano        | `bash domain-mom6.bash --no-mask --pes N` (regera o `LAYOUT`) |

## Resolução de caminhos

Como o instalador vive fora da árvore do acoplador, os scripts localizam o que
precisam por busca em vários locais (primeiro que existir vence):

- **Raiz do acoplador** (`COUPLER_ROOT`): ambiente → `./MONAN-Coupler`.
- **Sítio** (`site-jaci.bash`): `$SITE_ENV` → `sites/` → raiz → `install/` → `<COUPLER_ROOT>/run/setenv-site.bash` → `<COUPLER_ROOT>/install/` (legado).
- **Template** (`cray-gnu-monan.mk`): `$MKMF_TEMPLATE_SRC` → `templates/` → raiz → `install/templates/` → `<COUPLER_ROOT>/install/templates/`.

O `install.bash` confere **sítio e template antes do clone** (preflight),
falhando cedo e listando tudo que faltar de uma só vez. Também deixa uma cópia
da config de sítio em `<COUPLER_ROOT>/run/setenv-site.bash`, para que as
sessões de build (`source run/setenv-gnu.bash`) a encontrem sem o instalador —
assim o acoplador não precisa de um diretório `install/`.

## Etapas isoladas

Com o sistema já baixado e `COUPLER_ROOT` exportado:

```bash
export COUPLER_ROOT=/caminho/MONAN-Coupler
bash build.bash --from 2          # retoma a partir da etapa 2   (= make build FROM=2)
bash 2-mom.bash --only-nuopc      # só o cap NUOPC do MOM6
bash 1-monan.bash --skip-init-atm # só o core atmosphere
```

Equivalentes diretos via `make`: `make monan`, `make mom`, `make coupler`.
