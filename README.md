# Coupler-Install

Scripts de instalação do sistema acoplado **MONAN-A 2.0 × MOM6+SIS2**
(NUOPC-ESMF 8.9.1). Este repositório é **independente** do sistema acoplado: ele
baixa o `MONAN-Coupler` (com os modelos como submódulos) e compila tudo.

INPE / CGCT / DIMNT — GT Acoplamento de Modelos.

## Uso (um comando)

```bash
git clone https://github.com/GTA-DIMNT-CPTEC/Coupler-Install.git
cd Coupler-Install
bash install.bash
```

O `install.bash` faz `git clone --recursive --branch develop` do
`MONAN-Coupler` (trazendo `MONAN-Model`, `MOM6-examples` e os submódulos
aninhados) e, em seguida, executa as três etapas de instalação.

Opções: `--coupler-root DIR`, `--branch BRANCH`, `--no-install` (só baixa),
`--from N` / `--only N` (repassadas ao `build.bash`).

## Estrutura

```
Coupler-Install/
├── install.bash            ← ★ entrada: baixa (git recursivo) E instala
├── build.bash              ← orquestra as 3 etapas (sistema já baixado)
├── include.bash            ← biblioteca de funções (log, timer, clone, resolvedores)
├── 1-install-monan.bash    ← etapa 1 — MONAN-A 2.0 → lib/monan2, mod/monan2
├── 2-install-mom.bash      ← etapa 2 — MOM6+SIS2+FMS → lib/{fms,mom6,nuopc}
├── 3-install-coupler.bash  ← etapa 3 — linka bin/esmApp
├── sites/                  ← configuração por máquina (ESMF, módulos, alvos)
│   └── site-jaci.bash      ← Jaci (Cray XD2000 / PrgEnv-gnu) — padrão
└── templates/              ← templates de build
    └── cray-gnu-monan.mk   ← template mkmf Cray/GNU
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
| Rodar em outra máquina              | copie `sites/site-jaci.bash` → `sites/site-X.bash` e `export SITE_ENV=sites/site-X.bash` |
| Ajuste pontual sem editar arquivo   | `export VAR=valor` antes (tem prioridade sobre o sítio) |
| Outro template mkmf                 | `export MKMF_TEMPLATE_SRC=/caminho/template.mk`   |
| Outra raiz para o acoplador         | `--coupler-root DIR` ou `export COUPLER_ROOT=DIR` |
| Outro fork/branch dos modelos       | ajuste o `.gitmodules` do `MONAN-Coupler`         |

## Resolução de caminhos

Como o instalador vive fora da árvore do acoplador, os scripts localizam o que
precisam por busca em vários locais (primeiro que existir vence):

- **Raiz do acoplador** (`COUPLER_ROOT`): ambiente → `./MONAN-Coupler`.
- **Sítio** (`site-jaci.bash`): `$SITE_ENV` → `sites/` → raiz → `install/` → `<COUPLER_ROOT>/install/`.
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
bash build.bash --from 2        # retoma a partir da etapa 2
bash 2-install-mom.bash --only-nuopc  # só o cap NUOPC do MOM6
bash 1-install-monan.bash --skip-init-atm
```
