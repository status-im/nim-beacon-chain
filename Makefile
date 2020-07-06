# Copyright (c) 2019-2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

SHELL := bash # the shell used internally by "make"

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

# unconditionally built by the default Make target
TOOLS := \
	beacon_node \
	block_sim \
	deposit_contract \
	inspector \
	logtrace \
	nbench \
	nbench_spec_scenarios \
	ncli_db \
	ncli_hash_tree_root \
	ncli_pretty \
	ncli_query \
	ncli_transition \
	process_dashboard \
	stack_sizes \
	state_sim \
	validator_client

# bench_bls_sig_agggregation TODO reenable after bls v0.10.1 changes

TOOLS_DIRS := \
	beacon_chain \
	benchmarks \
	ncli \
	nbench \
	research \
	tools
TOOLS_CSV := $(subst $(SPACE),$(COMMA),$(TOOLS))

.PHONY: \
	all \
	deps \
	update \
	test \
	$(TOOLS) \
	clean_eth2_network_simulation_all \
	eth2_network_simulation \
	clean-testnet0 \
	testnet0 \
	clean-testnet1 \
	testnet1 \
	clean \
	libbacktrace \
	book \
	publish-book

ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included, so we update the submodules.
GIT_SUBMODULE_UPDATE := git submodule update --init --recursive
.DEFAULT:
	+@ echo -e "Git submodules not found. Running '$(GIT_SUBMODULE_UPDATE)'.\n"; \
		$(GIT_SUBMODULE_UPDATE) && \
		echo
# Now that the included *.mk files appeared, and are newer than this file, Make will restart itself:
# https://www.gnu.org/software/make/manual/make.html#Remaking-Makefiles
#
# After restarting, it will execute its original goal, so we don't have to start a child Make here
# with "$(MAKE) $(MAKECMDGOALS)". Isn't hidden control flow great?

else # "variables.mk" was included. Business as usual until the end of this file.

# default target, because it's the first one that doesn't start with '.'
all: | $(TOOLS) libnfuzz.so libnfuzz.a

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

ifeq ($(OS), Windows_NT)
  ifeq ($(ARCH), x86)
    # 32-bit Windows is not supported by libbacktrace/libunwind
    USE_LIBBACKTRACE := 0
  endif
endif

# "--define:release" implies "--stacktrace:off" and it cannot be added to config.nims
ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:debug -d:disable_libbacktrace
else
NIM_PARAMS := $(NIM_PARAMS) -d:release
endif

deps: | deps-common nat-libs beacon_chain.nims
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
endif

# maximum stack size (in bytes) mirroring Android limits
NIM_PARAMS := $(NIM_PARAMS) -d:stack_size=1000000

#- deletes and recreates "beacon_chain.nims" which on Windows is a copy instead of a proper symlink
update: | update-common
	rm -f beacon_chain.nims && \
		$(MAKE) beacon_chain.nims $(HANDLE_OUTPUT)

# symlink
beacon_chain.nims:
	ln -s beacon_chain.nimble $@

# nim-libbacktrace
libbacktrace:
	+ $(MAKE) -C vendor/nim-libbacktrace --no-print-directory BUILD_CXX_LIB=0

# Windows 10 with WSL enabled, but no distro installed, fails if "../../nimble.sh" is executed directly
# in a Makefile recipe but works when prefixing it with `bash`. No idea how the PATH is overridden.
DISABLE_TEST_FIXTURES_SCRIPT := 0
test: | build deps
ifeq ($(DISABLE_TEST_FIXTURES_SCRIPT), 0)
	V=$(V) scripts/setup_official_tests.sh
endif
	$(ENV_SCRIPT) nim test $(NIM_PARAMS) beacon_chain.nims && rm -f 0000-*.json

$(TOOLS): | build deps
	for D in $(TOOLS_DIRS); do [ -e "$${D}/$@.nim" ] && TOOL_DIR="$${D}" && break; done && \
		echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c -o:build/$@ $(NIM_PARAMS) "$${TOOL_DIR}/$@.nim"

clean_eth2_network_simulation_data:
	rm -rf tests/simulation/data

clean_eth2_network_simulation_all:
	rm -rf tests/simulation/{data,validators}

eth2_network_simulation: | build deps clean_eth2_network_simulation_data
	+ GIT_ROOT="$$PWD" NIMFLAGS="$(NIMFLAGS)" LOG_LEVEL="$(LOG_LEVEL)" tests/simulation/start-in-tmux.sh

clean-testnet0:
	rm -rf build/data/testnet0*

clean-testnet1:
	rm -rf build/data/testnet1*

# - we're getting the preset from a testnet-specific .env file
# - try SCRIPT_PARAMS="--skipGoerliKey"
testnet0 testnet1: | build deps
	source scripts/$@.env; \
		NIM_PARAMS="$(NIM_PARAMS)" LOG_LEVEL="$(LOG_LEVEL)" $(ENV_SCRIPT) nim $(NIM_PARAMS) scripts/connect_to_testnet.nims $(SCRIPT_PARAMS) --const-preset=$$CONST_PRESET --dev-build $@

clean-altona:
	rm -rf build/data/shared_altona*

altona: | build deps
	NIM_PARAMS="$(NIM_PARAMS)" LOG_LEVEL="$(LOG_LEVEL)" $(ENV_SCRIPT) nim $(NIM_PARAMS) scripts/connect_to_testnet.nims $(SCRIPT_PARAMS) shared/altona

altona-dev: | build deps
	NIM_PARAMS="$(NIM_PARAMS)" LOG_LEVEL="DEBUG; TRACE:discv5,networking; REQUIRED:none; DISABLED:none" $(ENV_SCRIPT) nim $(NIM_PARAMS) scripts/connect_to_testnet.nims $(SCRIPT_PARAMS) shared/altona

ctail: | build deps
	mkdir -p vendor/.nimble/bin/
	$(ENV_SCRIPT) nim -d:danger -o:vendor/.nimble/bin/ctail c vendor/nim-chronicles-tail/ctail.nim

ntu: | build deps
	mkdir -p vendor/.nimble/bin/
	$(ENV_SCRIPT) nim -d:danger -o:vendor/.nimble/bin/ntu c vendor/nim-testutils/ntu.nim

clean: | clean-common
	rm -rf build/{$(TOOLS_CSV),all_tests,*_node,*ssz*,beacon_node_*,block_sim,state_sim,transition*}
ifneq ($(USE_LIBBACKTRACE), 0)
	+ $(MAKE) -C vendor/nim-libbacktrace clean $(HANDLE_OUTPUT)
endif

libnfuzz.so: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c -d:release --app:lib --noMain --nimcache:nimcache/libnfuzz -o:build/$@.0 $(NIM_PARAMS) nfuzz/libnfuzz.nim && \
		rm -f build/$@ && \
		ln -s $@.0 build/$@

libnfuzz.a: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		rm -f build/$@ && \
		$(ENV_SCRIPT) nim c -d:release --app:staticlib --noMain --nimcache:nimcache/libnfuzz_static -o:build/$@ $(NIM_PARAMS) nfuzz/libnfuzz.nim && \
		[[ -e "$@" ]] && mv "$@" build/ # workaround for https://github.com/nim-lang/Nim/issues/12745

book:
	cd docs/the_nimbus_book && \
	mdbook build

publish-book: | book
	git worktree add tmp-book gh-pages && \
	rm -rf tmp-book/* && \
	cp -a docs/the_nimbus_book/book/* tmp-book/ && \
	cd tmp-book && \
	git add . && { \
		git commit -m "make publish-book" && \
		git push origin gh-pages || true; } && \
	cd .. && \
	git worktree remove -f tmp-book && \
	rm -rf tmp-book

endif # "variables.mk" was not included
