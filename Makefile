# Copyright (c) 2019-2021 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

SHELL := bash # the shell used internally by "make"

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

# we set its default value before LOG_LEVEL is used in "variables.mk"
LOG_LEVEL := DEBUG

# used by Make targets that launch a beacon node
RUNTIME_LOG_LEVEL := INFO

LINK_PCRE := 0

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

NODE_ID := 0
BASE_PORT := 9000
BASE_RPC_PORT := 9190
BASE_METRICS_PORT := 8008
WEB3_URL := "wss://goerli.infura.io/ws/v3/809a18497dd74102b5f37d25aae3c85a"
VALIDATORS := 1
CPU_LIMIT := 0
BUILD_END_MSG := "\\e[92mBuild completed successfully:\\e[39m"

ifeq ($(CPU_LIMIT), 0)
	CPU_LIMIT_CMD :=
else
	CPU_LIMIT_CMD := cpulimit --limit=$(CPU_LIMIT) --foreground --
endif

# unconditionally built by the default Make target
# TODO re-enable ncli_query if/when it works again
TOOLS := \
	nimbus_beacon_node \
	deposit_contract \
	resttest \
	inspector \
	logtrace \
	nbench \
	nbench_spec_scenarios \
	ncli \
	ncli_db \
	process_dashboard \
	stack_sizes \
	nimbus_validator_client \
	nimbus_signing_process
.PHONY: $(TOOLS)

# bench_bls_sig_agggregation TODO reenable after bls v0.10.1 changes

TOOLS_DIRS := \
	beacon_chain \
	beacon_chain/eth1 \
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
	clean_eth2_network_simulation_all \
	eth2_network_simulation \
	clean-testnet0 \
	testnet0 \
	clean-testnet1 \
	testnet1 \
	clean \
	libbacktrace \
	book \
	publish-book \
	dist-amd64 \
	dist-arm64 \
	dist-arm \
	dist-win64 \
	dist-macos \
	dist-macos-arm64 \
	dist \
	benchmarks

ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included, so we update the submodules.
#
# The `git reset ...` will try to fix a `make update` that was interrupted
# with Ctrl+C after deleting the working copy and before getting a chance to
# restore it in $(BUILD_SYSTEM_DIR).
GIT_SUBMODULE_UPDATE := git submodule update --init --recursive
.DEFAULT:
	+@ echo -e "Git submodules not found. Running '$(GIT_SUBMODULE_UPDATE)'.\n"; \
		$(GIT_SUBMODULE_UPDATE) && \
		git submodule foreach --quiet 'git reset --quiet --hard' && \
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
  # libbacktrace/libunwind is disabled on Windows.
  USE_LIBBACKTRACE := 0
endif

DEPOSITS_DELAY := 0

#- "--define:release" cannot be added to "config.nims"
#- disable Nim's default parallelisation because it starts too many processes for too little gain
NIM_PARAMS += -d:release --parallelBuild:1

ifeq ($(USE_LIBBACKTRACE), 0)
# Blame Jacek for the lack of line numbers in your stack traces ;-)
NIM_PARAMS += --stacktrace:on --excessiveStackTrace:on --linetrace:off -d:disable_libbacktrace
endif

deps: | deps-common nat-libs build/generate_makefile
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
endif

#- deletes binaries that might need to be rebuilt after a Git pull
update: | update-common
	rm -f build/generate_makefile
	rm -fr nimcache/

# nim-libbacktrace
libbacktrace:
	+ "$(MAKE)" -C vendor/nim-libbacktrace --no-print-directory BUILD_CXX_LIB=0

# test binaries that can output an XML report
XML_TEST_BINARIES := \
	test_fixture_const_sanity_check_minimal \
	test_fixture_const_sanity_check_mainnet \
	test_fixture_ssz_generic_types \
	test_fixture_ssz_consensus_objects \
	test_official_interchange_vectors \
	all_tests \
	test_keystore

# test suite
TEST_BINARIES := \
	proto_array \
	fork_choice \
	test_ssz_roundtrip \
	state_sim \
	block_sim
.PHONY: $(TEST_BINARIES) $(XML_TEST_BINARIES)

test_fixture_const_sanity_check_minimal: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) scripts/compile_nim_program.sh \
			$@ \
			"tests/official/test_fixture_const_sanity_check.nim" \
			$(NIM_PARAMS) -d:const_preset=minimal -d:chronicles_sinks="json[file]" && \
		echo -e $(BUILD_END_MSG) "build/$@"

test_fixture_const_sanity_check_mainnet: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) scripts/compile_nim_program.sh \
			$@ \
			"tests/official/test_fixture_const_sanity_check.nim" \
			$(NIM_PARAMS) -d:const_preset=mainnet -d:chronicles_sinks="json[file]" && \
		echo -e $(BUILD_END_MSG) "build/$@"

# Generic SSZ test, doesn't use consensus objects minimal/mainnet presets
test_fixture_ssz_generic_types: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) scripts/compile_nim_program.sh \
			$@ \
			"tests/official/$@.nim" \
			$(NIM_PARAMS) -d:chronicles_log_level=TRACE -d:chronicles_sinks="json[file]" && \
		echo -e $(BUILD_END_MSG) "build/$@"

# Consensus object SSZ tests
test_fixture_ssz_consensus_objects: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) scripts/compile_nim_program.sh \
			$@ \
			"tests/official/$@.nim" \
			$(NIM_PARAMS) -d:chronicles_log_level=TRACE -d:chronicles_sinks="json[file]" && \
		echo -e $(BUILD_END_MSG) "build/$@"

# EIP-3076 - Slashing interchange
test_official_interchange_vectors: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) scripts/compile_nim_program.sh \
			$@ \
			"tests/slashing_protection/$@.nim" \
			$(NIM_PARAMS) -d:chronicles_log_level=TRACE -d:const_preset=mainnet -d:chronicles_sinks="json[file]" && \
		echo -e $(BUILD_END_MSG) "build/$@"

# Mainnet config
proto_array: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) scripts/compile_nim_program.sh \
			$@ \
			"beacon_chain/fork_choice/$@.nim" \
			$(NIM_PARAMS) -d:const_preset=mainnet -d:chronicles_sinks="json[file]" && \
		echo -e $(BUILD_END_MSG) "build/$@"

fork_choice: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) scripts/compile_nim_program.sh \
			$@ \
			"beacon_chain/fork_choice/$@.nim" \
			$(NIM_PARAMS) -d:const_preset=mainnet -d:chronicles_sinks="json[file]" && \
		echo -e $(BUILD_END_MSG) "build/$@"

all_tests: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) scripts/compile_nim_program.sh \
			$@ \
			"tests/$@.nim" \
			$(NIM_PARAMS) -d:chronicles_log_level=TRACE -d:const_preset=mainnet -d:chronicles_sinks="json[file]" && \
		echo -e $(BUILD_END_MSG) "build/$@"

# TODO `test_ssz_roundtrip` is extracted from the rest of the tests because it's incompatible with unittest2
test_ssz_roundtrip: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) scripts/compile_nim_program.sh \
			$@ \
			"tests/$@.nim" \
			$(NIM_PARAMS) -d:chronicles_log_level=TRACE -d:const_preset=mainnet -d:chronicles_sinks="json[file]" && \
		echo -e $(BUILD_END_MSG) "build/$@"

# TODO `test_keystore` is extracted from the rest of the tests because it uses conflicting BLST headers
test_keystore: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) scripts/compile_nim_program.sh \
			$@ \
			"tests/$@.nim" \
			$(NIM_PARAMS) -d:chronicles_log_level=TRACE -d:const_preset=mainnet -d:chronicles_sinks="json[file]" && \
		echo -e $(BUILD_END_MSG) "build/$@"

# State and block sims; getting to 4th epoch triggers consensus checks
state_sim: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) scripts/compile_nim_program.sh \
			$@ \
			"research/$@.nim" \
			$(NIM_PARAMS) -d:const_preset=mainnet && \
		echo -e $(BUILD_END_MSG) "build/$@"

block_sim: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) scripts/compile_nim_program.sh \
			$@ \
			"research/$@.nim" \
			$(NIM_PARAMS) -d:const_preset=mainnet && \
		echo -e $(BUILD_END_MSG) "build/$@"

DISABLE_TEST_FIXTURES_SCRIPT := 0
# This parameter passing scheme is ugly, but short.
test: | $(XML_TEST_BINARIES) $(TEST_BINARIES)
ifeq ($(DISABLE_TEST_FIXTURES_SCRIPT), 0)
	V=$(V) scripts/setup_official_tests.sh
endif
	tests/simulation/restapi.sh
	for TEST_BINARY in $(XML_TEST_BINARIES); do \
		PARAMS="--xml:build/$${TEST_BINARY}.xml --console"; \
		echo -e "\nRunning $${TEST_BINARY} $${PARAMS}\n"; \
		build/$${TEST_BINARY} $${PARAMS} || { echo -e "\n$${TEST_BINARY} $${PARAMS} failed; Aborting."; exit 1; }; \
		done; \
		rm -rf 0000-*.json t_slashprot_migration.* *.log block_sim_db
	for TEST_BINARY in $(TEST_BINARIES); do \
		PARAMS=""; \
		if [[ "$${TEST_BINARY}" == "state_sim" ]]; then PARAMS="--validators=6000 --slots=128"; \
		elif [[ "$${TEST_BINARY}" == "block_sim" ]]; then PARAMS="--validators=6000 --slots=128"; \
		fi; \
		echo -e "\nRunning $${TEST_BINARY} $${PARAMS}\n"; \
		build/$${TEST_BINARY} $${PARAMS} || { echo -e "\n$${TEST_BINARY} $${PARAMS} failed; Aborting."; exit 1; }; \
		done; \
		rm -rf 0000-*.json t_slashprot_migration.* *.log block_sim_db

# It's OK to only build this once. `make update` deletes the binary, forcing a rebuild.
ifneq ($(USE_LIBBACKTRACE), 0)
build/generate_makefile: | libbacktrace
endif
build/generate_makefile: tools/generate_makefile.nim | deps-common
	echo -e $(BUILD_MSG) "$@" && \
	$(ENV_SCRIPT) nim c -o:$@ $(NIM_PARAMS) tools/generate_makefile.nim && \
	echo -e $(BUILD_END_MSG) "$@"

# GCC's LTO parallelisation is able to detect a GNU Make jobserver and get its
# maximum number of processes from there, but only if we use the "+" prefix.
# Without it, it will default to the number of CPU cores, which can be a
# problem on low-memory systems.
# It also requires Make to pass open file descriptors to the GCC process,
# which is not possible if we let Nim handle this, so we generate and use a
# makefile instead.
$(TOOLS): | build deps
	+ for D in $(TOOLS_DIRS); do [ -e "$${D}/$@.nim" ] && TOOL_DIR="$${D}" && break; done && \
		echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) scripts/compile_nim_program.sh $@ "$${TOOL_DIR}/$@.nim" $(NIM_PARAMS) && \
		echo -e $(BUILD_END_MSG) "build/$@"

clean_eth2_network_simulation_data:
	rm -rf tests/simulation/data

clean_eth2_network_simulation_all:
	rm -rf tests/simulation/{data,validators}

GOERLI_TESTNETS_PARAMS := \
  --web3-url=$(WEB3_URL) \
  --tcp-port=$$(( $(BASE_PORT) + $(NODE_ID) )) \
  --udp-port=$$(( $(BASE_PORT) + $(NODE_ID) )) \
  --metrics \
  --metrics-port=$$(( $(BASE_METRICS_PORT) + $(NODE_ID) )) \
  --rpc \
  --rpc-port=$$(( $(BASE_RPC_PORT) +$(NODE_ID) ))

eth2_network_simulation: | build deps clean_eth2_network_simulation_all
	+ GIT_ROOT="$$PWD" NIMFLAGS="$(NIMFLAGS)" LOG_LEVEL="$(LOG_LEVEL)" tests/simulation/start-in-tmux.sh
	killall prometheus &>/dev/null

clean-testnet0:
	rm -rf build/data/testnet0*

clean-testnet1:
	rm -rf build/data/testnet1*

testnet0 testnet1: | nimbus_beacon_node nimbus_signing_process
	build/nimbus_beacon_node \
		--network=$@ \
		--log-level="$(RUNTIME_LOG_LEVEL)" \
		--data-dir=build/data/$@_$(NODE_ID) \
		$(GOERLI_TESTNETS_PARAMS) $(NODE_PARAMS)

#- https://www.gnu.org/software/make/manual/html_node/Multi_002dLine.html
#- macOS doesn't support "=" at the end of "define FOO": https://stackoverflow.com/questions/13260396/gnu-make-3-81-eval-function-not-working
define CONNECT_TO_NETWORK
  scripts/makedir.sh build/data/shared_$(1)_$(NODE_ID)

	scripts/make_prometheus_config.sh \
		--nodes 1 \
		--base-metrics-port $$(($(BASE_METRICS_PORT) + $(NODE_ID))) \
		--config-file "build/data/shared_$(1)_$(NODE_ID)/prometheus.yml"

	[ "$(3)" == "FastSync" ] && { export CHECKPOINT_PARAMS="--finalized-checkpoint-state=vendor/eth2-testnets/shared/$(1)/recent-finalized-state.ssz \
																													--finalized-checkpoint-block=vendor/eth2-testnets/shared/$(1)/recent-finalized-block.ssz" ; }; \
	$(CPU_LIMIT_CMD) build/$(2) \
		--network=$(1) \
		--log-level="$(RUNTIME_LOG_LEVEL)" \
		--log-file=build/data/shared_$(1)_$(NODE_ID)/nbc_bn_$$(date +"%Y%m%d%H%M%S").log \
		--data-dir=build/data/shared_$(1)_$(NODE_ID) \
		$$CHECKPOINT_PARAMS $(GOERLI_TESTNETS_PARAMS) $(NODE_PARAMS)
endef

define CONNECT_TO_NETWORK_IN_DEV_MODE
  scripts/makedir.sh build/data/shared_$(1)_$(NODE_ID)

	scripts/make_prometheus_config.sh \
		--nodes 1 \
		--base-metrics-port $$(($(BASE_METRICS_PORT) + $(NODE_ID))) \
		--config-file "build/data/shared_$(1)_$(NODE_ID)/prometheus.yml"

	$(CPU_LIMIT_CMD) build/$(2) \
		--network=$(1) \
		--log-level="DEBUG; TRACE:discv5,networking; REQUIRED:none; DISABLED:none" \
		--data-dir=build/data/shared_$(1)_$(NODE_ID) \
		$(GOERLI_TESTNETS_PARAMS) --dump $(NODE_PARAMS)
endef

define CONNECT_TO_NETWORK_WITH_VALIDATOR_CLIENT
	# if launching a VC as well - send the BN looking nowhere for validators/secrets
	scripts/makedir.sh build/data/shared_$(1)_$(NODE_ID)
	scripts/makedir.sh build/data/shared_$(1)_$(NODE_ID)/empty_dummy_folder

	scripts/make_prometheus_config.sh \
		--nodes 1 \
		--base-metrics-port $$(($(BASE_METRICS_PORT) + $(NODE_ID))) \
		--config-file "build/data/shared_$(1)_$(NODE_ID)/prometheus.yml"

	$(CPU_LIMIT_CMD) build/$(2) \
		--network=$(1) \
		--log-level="$(RUNTIME_LOG_LEVEL)" \
		--log-file=build/data/shared_$(1)_$(NODE_ID)/nbc_bn_$$(date +"%Y%m%d%H%M%S").log \
		--data-dir=build/data/shared_$(1)_$(NODE_ID) \
		--validators-dir=build/data/shared_$(1)_$(NODE_ID)/empty_dummy_folder \
		--secrets-dir=build/data/shared_$(1)_$(NODE_ID)/empty_dummy_folder \
		$(GOERLI_TESTNETS_PARAMS) $(NODE_PARAMS) &

	sleep 4

	build/nimbus_validator_client \
		--log-level="$(RUNTIME_LOG_LEVEL)" \
		--log-file=build/data/shared_$(1)_$(NODE_ID)/nbc_vc_$$(date +"%Y%m%d%H%M%S").log \
		--data-dir=build/data/shared_$(1)_$(NODE_ID) \
		--rpc-port=$$(( $(BASE_RPC_PORT) +$(NODE_ID) ))
endef

define MAKE_DEPOSIT_DATA
	build/nimbus_beacon_node deposits createTestnetDeposits \
		--network=$(1) \
		--new-wallet-file=build/data/shared_$(1)_$(NODE_ID)/wallet.json \
		--out-validators-dir=build/data/shared_$(1)_$(NODE_ID)/validators \
		--out-secrets-dir=build/data/shared_$(1)_$(NODE_ID)/secrets \
		--out-deposits-file=$(1)-deposits_data-$$(date +"%Y%m%d%H%M%S").json \
		--count=$(VALIDATORS)
endef

define MAKE_DEPOSIT
	build/nimbus_beacon_node deposits createTestnetDeposits \
		--network=$(1) \
		--out-deposits-file=nbc-$(1)-deposits.json \
		--new-wallet-file=build/data/shared_$(1)_$(NODE_ID)/wallet.json \
		--out-validators-dir=build/data/shared_$(1)_$(NODE_ID)/validators \
		--out-secrets-dir=build/data/shared_$(1)_$(NODE_ID)/secrets \
		--count=$(VALIDATORS)

	build/deposit_contract sendDeposits \
		--web3-url=$(WEB3_URL) \
		--deposit-contract=$$(cat vendor/eth2-testnets/shared/$(1)/deposit_contract.txt) \
		--deposits-file=nbc-$(1)-deposits.json \
		--min-delay=$(DEPOSITS_DELAY) \
		--ask-for-key
endef

define CLEAN_NETWORK
	rm -rf build/data/shared_$(1)*/db
	rm -rf build/data/shared_$(1)*/dump
	rm -rf build/data/shared_$(1)*/*.log
endef

###
### Pyrmont
###
pyrmont-build: | nimbus_beacon_node nimbus_signing_process

# https://www.gnu.org/software/make/manual/html_node/Call-Function.html#Call-Function
pyrmont: | pyrmont-build
	$(call CONNECT_TO_NETWORK,pyrmont,nimbus_beacon_node)

pyrmont-vc: | pyrmont-build nimbus_validator_client
	$(call CONNECT_TO_NETWORK_WITH_VALIDATOR_CLIENT,pyrmont,nimbus_beacon_node)

ifneq ($(LOG_LEVEL), TRACE)
pyrmont-dev:
	+ "$(MAKE)" LOG_LEVEL=TRACE $@
else
pyrmont-dev: | pyrmont-build
	$(call CONNECT_TO_NETWORK_IN_DEV_MODE,pyrmont,nimbus_beacon_node)
endif

pyrmont-dev-deposit: | pyrmont-build deposit_contract
	$(call MAKE_DEPOSIT,pyrmont)

clean-pyrmont:
	$(call CLEAN_NETWORK,pyrmont)


###
### Prater
###
prater-build: | nimbus_beacon_node nimbus_signing_process

# https://www.gnu.org/software/make/manual/html_node/Call-Function.html#Call-Function
prater: | prater-build
	$(call CONNECT_TO_NETWORK,prater,nimbus_beacon_node)

prater-vc: | prater-build nimbus_validator_client
	$(call CONNECT_TO_NETWORK_WITH_VALIDATOR_CLIENT,prater,nimbus_beacon_node)

ifneq ($(LOG_LEVEL), TRACE)
prater-dev:
	+ "$(MAKE)" LOG_LEVEL=TRACE $@
else
prater-dev: | prater-build
	$(call CONNECT_TO_NETWORK_IN_DEV_MODE,prater,nimbus_beacon_node)
endif

prater-dev-deposit: | prater-build deposit_contract
	$(call MAKE_DEPOSIT,prater)

clean-prater:
	$(call CLEAN_NETWORK,prater)

###
### Other
###

ctail: | build deps
	mkdir -p vendor/.nimble/bin/
	+ $(ENV_SCRIPT) nim -d:danger -o:vendor/.nimble/bin/ctail c vendor/nim-chronicles-tail/ctail.nim

ntu: | build deps
	mkdir -p vendor/.nimble/bin/
	+ $(ENV_SCRIPT) nim -d:danger -o:vendor/.nimble/bin/ntu c vendor/nim-testutils/ntu.nim

clean: | clean-common
	rm -rf build/{$(TOOLS_CSV),all_tests,test_*,proto_array,fork_choice,*.a,*.so,*_node,*ssz*,nimbus_*,beacon_node*,block_sim,state_sim,transition*,generate_makefile}
ifneq ($(USE_LIBBACKTRACE), 0)
	+ "$(MAKE)" -C vendor/nim-libbacktrace clean $(HANDLE_OUTPUT)
endif

libnfuzz.so: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c -d:release --app:lib --noMain --nimcache:nimcache/libnfuzz -o:build/$@.0 $(NIM_PARAMS) nfuzz/libnfuzz.nim && \
		echo -e $(BUILD_END_MSG) "build/$@" && \
		rm -f build/$@ && \
		ln -s $@.0 build/$@

libnfuzz.a: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		rm -f build/$@ && \
		$(ENV_SCRIPT) nim c -d:release --app:staticlib --noMain --nimcache:nimcache/libnfuzz_static -o:build/$@ $(NIM_PARAMS) nfuzz/libnfuzz.nim && \
		echo -e $(BUILD_END_MSG) "build/$@" && \
		[[ -e "$@" ]] && mv "$@" build/ || true # workaround for https://github.com/nim-lang/Nim/issues/12745

book:
	which mdbook &>/dev/null || { echo "'mdbook' not found in PATH. See 'docs/README.md'. Aborting."; exit 1; }
	which mdbook-toc &>/dev/null || { echo "'mdbook-toc' not found in PATH. See 'docs/README.md'. Aborting."; exit 1; }
	which mdbook-open-on-gh &>/dev/null || { echo "'mdbook-open-on-gh' not found in PATH. See 'docs/README.md'. Aborting."; exit 1; }
	cd docs/the_nimbus_book && \
	mdbook build

auditors-book:
	cd docs/the_auditors_handbook && \
	mdbook build

publish-book: | book auditors-book
	CURRENT_BRANCH="$$(git rev-parse --abbrev-ref HEAD)"; \
		if [[ "$${CURRENT_BRANCH}" != "stable" && "$${CURRENT_BRANCH}" != "unstable" ]]; then \
			echo -e "\nWarning: you're publishing the books from a branch that is neither 'stable' nor 'unstable'!\n"; \
		fi
	git branch -D gh-pages && \
	git branch --track gh-pages origin/gh-pages && \
	git worktree add tmp-book gh-pages && \
	rm -rf tmp-book/* && \
	mkdir -p tmp-book/auditors-book && \
	cp -a docs/the_nimbus_book/CNAME tmp-book/ && \
	cp -a docs/the_nimbus_book/book/* tmp-book/ && \
	cp -a docs/the_auditors_handbook/book/* tmp-book/auditors-book/ && \
	cd tmp-book && \
	git add . && { \
		git commit -m "make publish-book" && \
		git push origin gh-pages || true; } && \
	cd .. && \
	git worktree remove -f tmp-book && \
	rm -rf tmp-book

dist-amd64:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh amd64

dist-arm64:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh arm64

dist-arm:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh arm

dist-win64:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh win64

dist-macos:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh macos

dist-macos-arm64:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh macos-arm64

dist:
	+ $(MAKE) dist-amd64
	+ $(MAKE) dist-arm64
	+ $(MAKE) dist-arm
	+ $(MAKE) dist-win64
	+ $(MAKE) dist-macos
	+ $(MAKE) dist-macos-arm64

#- this simple test will show any missing dynamically-linked Glibc symbols in the target distro
dist-test:
	docker rm nimbus-eth2-dist-test $(HANDLE_OUTPUT) || true
	cd docker/dist && \
		for DISTRO in debian-bullseye; do \
			DOCKER_BUILDKIT=1 docker build -f Dockerfile.$${DISTRO} -t nimbus-eth2-dist-test --progress=plain --build-arg USER_ID=$$(id -u) --build-arg GROUP_ID=$$(id -g) . && \
			docker run --rm --name nimbus-eth2-dist-test -v $(CURDIR):/home/user/nimbus-eth2 nimbus-eth2-dist-test; \
		done

#- Build and run benchmarks using an external repo (which can be used easily on
#  older commits, before this Make target was added).
#- It's up to the user to create a benchmarking environment that minimises the
#  results spread. We're showing a 95% CI bar to help visualise that.
benchmarks:
	+ vendor/nimbus-benchmarking/run_nbc_benchmarks.sh --output-type d3

endif # "variables.mk" was not included
