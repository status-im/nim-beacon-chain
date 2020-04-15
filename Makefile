# Copyright (c) 2019-2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

SHELL := bash # the shell used internally by "make"

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

# we don't want an error here, so we can handle things later, in the build-system-checks target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

# unconditionally built by the default Make target
TOOLS := \
	beacon_node \
	inspector \
	logtrace \
	deposit_contract \
	ncli_hash_tree_root \
	ncli_pretty \
	ncli_transition \
	process_dashboard
	# bench_bls_sig_agggregation TODO reenable after bls v0.10.1 changes
TOOLS_DIRS := \
	beacon_chain \
	benchmarks \
	ncli \
	research \
	tests/simulation
TOOLS_CSV := $(subst $(SPACE),$(COMMA),$(TOOLS))

.PHONY: \
	all \
	build-system-checks \
	deps \
	update \
	test \
	$(TOOLS) \
	clean_eth2_network_simulation_files \
	eth2_network_simulation \
	clean-testnet0 \
	testnet0 \
	clean-testnet1 \
	testnet1 \
	clean \
	libbacktrace

ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included. We can only execute one target in this state.
all: | build-system-checks
else
all: | build-system-checks $(TOOLS) libnfuzz.so libnfuzz.a
endif

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

# "--define:release" implies "--stacktrace:off" and it cannot be added to config.nims
ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:debug -d:disable_libbacktrace
else
NIM_PARAMS := $(NIM_PARAMS) -d:release
endif

#- the Windows build fails on Azure Pipelines if we have Unicode symbols copy/pasted here,
#  so we encode them in ASCII
GIT_SUBMODULE_UPDATE := git submodule update --init --recursive
build-system-checks:
	@[[ -e "$(BUILD_SYSTEM_DIR)/makefiles" ]] || { \
		echo -e "'$(BUILD_SYSTEM_DIR)/makefiles' not found. Running '$(GIT_SUBMODULE_UPDATE)'.\n"; \
		$(GIT_SUBMODULE_UPDATE); \
		CHECKMARK="\xe2\x9c\x94\xef\xb8\x8f"; \
		echo -e "\n$${CHECKMARK}$${CHECKMARK}$${CHECKMARK} Successfully fetched all required internal dependencies."; \
		echo -e "        You should now \e[4mre-run '$(MAKE)' to build Nimbus\e[0m\n"; \
		}; \
		exit 0

deps: | deps-common beacon_chain.nims
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
endif

#- deletes and recreates "beacon_chain.nims" which on Windows is a copy instead of a proper symlink
update: | update-common
	rm -f beacon_chain.nims && \
		$(MAKE) beacon_chain.nims $(HANDLE_OUTPUT)

# symlink
beacon_chain.nims:
	ln -s beacon_chain.nimble $@

# nim-libbacktrace
libbacktrace:
	+ $(MAKE) -C vendor/nim-libbacktrace BUILD_CXX_LIB=0 $(HANDLE_OUTPUT)

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

clean_eth2_network_simulation_files:
	rm -rf tests/simulation/{data,validators}

eth2_network_simulation: | build deps clean_eth2_network_simulation_files process_dashboard
	+ GIT_ROOT="$$PWD" NIMFLAGS="$(NIMFLAGS)" LOG_LEVEL="$(LOG_LEVEL)" tests/simulation/start.sh

clean-testnet0:
	rm -rf build/data/testnet0

clean-testnet1:
	rm -rf build/data/testnet1

testnet0: | build deps
	NIM_PARAMS="$(NIM_PARAMS)" LOG_LEVEL="$(LOG_LEVEL)" $(ENV_SCRIPT) nim $(NIM_PARAMS) scripts/connect_to_testnet.nims $(SCRIPT_PARAMS) testnet0

testnet1: | build deps
	NIM_PARAMS="$(NIM_PARAMS)" LOG_LEVEL="$(LOG_LEVEL)" $(ENV_SCRIPT) nim $(NIM_PARAMS) scripts/connect_to_testnet.nims $(SCRIPT_PARAMS) testnet1

clean: | clean-common
	rm -rf build/{$(TOOLS_CSV),all_tests,*_node,*ssz*,beacon_node_testnet*,state_sim,transition*}
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
