# =============================================================================
# Makefile — ATALHOS para o instalador (camada fina sobre os scripts .bash).
#
# ATENÇÃO: este NÃO é o build do acoplador. O executável bin/esmApp é gerado
# pelo Makefile do MONAN-Coupler. Aqui cada alvo apenas chama o script .bash
# correspondente — nada de lógica de compilação.
#
# Uso:  make [alvo] [VAR=valor]      (veja 'make help')
# Ex.:  make                         # baixa o sistema e instala tudo
#       make download                # só baixa (sem compilar)
#       make build FROM=2            # retoma as etapas a partir da 2
#       make install COUPLER_ROOT=/scratch/$USER/MC
#       make check                   # sanidade (bash -n em todos os scripts)
# =============================================================================
SHELL  := /bin/bash
BRANCH ?= develop

.PHONY: all install download build monan mom coupler check help

all: install            ## (padrão) baixa o sistema (recursivo) e instala tudo

install:                ## download recursivo + 3 etapas
	bash install.bash --branch $(BRANCH) $(if $(COUPLER_ROOT),--coupler-root $(COUPLER_ROOT))

download:               ## só baixa o sistema (sem compilar)
	bash install.bash --no-install --branch $(BRANCH) $(if $(COUPLER_ROOT),--coupler-root $(COUPLER_ROOT))

build:                  ## só as 3 etapas (já baixado); use FROM=N ou ONLY=N
	bash build.bash $(if $(FROM),--from $(FROM)) $(if $(ONLY),--only $(ONLY))

monan:                  ## etapa 1 — MONAN-A 2.0
	bash 1-monan.bash

mom:                    ## etapa 2 — MOM6+SIS2+FMS
	bash 2-mom.bash

coupler:                ## etapa 3 — linka bin/esmApp
	bash 3-coupler.bash

check:                  ## sanidade: bash -n em todos os scripts
	@ok=1; for f in *.bash sites/*.bash; do bash -n "$$f" && echo "OK $$f" || ok=0; done; [ $$ok = 1 ]

help:                   ## lista os alvos disponíveis
	@grep -E '^[a-z][a-z-]*:.*##' $(MAKEFILE_LIST) | sort \
	  | awk -F':.*##' '{printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}'
