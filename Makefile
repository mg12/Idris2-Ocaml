PREFIX ?= $(HOME)/.idris2
IDRIS2 ?= idris2

ifeq (,$(shell which $(IDRIS2)))
$(error IDRIS2 should point to my/path/to/idris2)
endif

ifndef IDRIS2_SOURCE_PATH
$(error IDRIS2_SOURCE_PATH containing ./support/refc/ is not defined)
endif

MAJOR=0
MINOR=6
PATCH=0

CFLAGS = -fPIE -Wno-pointer-sign -Wno-discarded-qualifiers

export IDRIS2_VERSION := ${MAJOR}.${MINOR}.${PATCH}

.PHONY: all
all: build install-support test

.PHONY: support
support:
	cd support/ && cc $(CFLAGS) -O2 -c ocaml_rts.c -I `ocamlc -where`  -I ../$(IDRIS2_SOURCE_PATH)/support/c/ -I ../$(IDRIS2_SOURCE_PATH)/support/refc/

.PHONY: install-support
install-support: support
	mkdir -p ${PREFIX}/idris2-${IDRIS2_VERSION}/support/ocaml
	install support/ocaml_rts.o ${PREFIX}/idris2-${IDRIS2_VERSION}/support/ocaml
	install support/OcamlRts.ml ${PREFIX}/idris2-${IDRIS2_VERSION}/support/ocaml

.PHONY: stop-instances
stop-instances:
	killall -q scheme || true
	killall -q idris2.so || true
	killall -q idris2 || true

.PHONY: build
build: stop-instances
	$(IDRIS2) --build idris2-ocaml.ipkg

.PHONY: test
test:
	./build/exec/idris2-ocaml --cg ocaml-native $(IDRIS2_SOURCE_PATH)/tests/idris2/api/api001/Hello.idr -o ./test-hello-idris-cg-ocaml-native
	./build/exec/test-hello-idris-cg-ocaml-native
