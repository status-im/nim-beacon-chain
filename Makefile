# Copyright (c) 2019-2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

SHELL := bash # the shell used internally by "make"

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

# we set its default value before LOG_LEVEL is used in "variables.mk"
LOG_LEVEL := INFO

LINK_PCRE := 0

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

NODE_ID := 0
BASE_PORT := 9000
BASE_RPC_PORT := 9190
BASE_METRICS_PORT := 8008
GOERLI_WEB3_URL := "wss://goerli.infura.io/ws/v3/809a18497dd74102b5f37d25aae3c85a"
VALIDATORS := 1
CPU_LIMIT := 0

ifeq ($(CPU_LIMIT), 0)
	CPU_LIMIT_CMD :=
else
	CPU_LIMIT_CMD := cpulimit --limit=$(CPU_LIMIT) --foreground --
endif

# unconditionally built by the default Make target
# TODO re-enable ncli_query if/when it works again
TOOLS := \
	nimbus_beacon_node \
	block_sim \
	deposit_contract \
	inspector \
	logtrace \
	nbench \
	nbench_spec_scenarios \
	ncli \
	ncli_db \
	process_dashboard \
	stack_sizes \
	state_sim \
	nimbus_validator_client \
	nimbus_signing_process

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
	publish-book \
	dist

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

# "--define:release" cannot be added to config.nims
ifeq ($(USE_LIBBACKTRACE), 0)
# Blame Jacek for the lack of line numbers in your stack traces ;-)
NIM_PARAMS := $(NIM_PARAMS) -d:release --stacktrace:on --excessiveStackTrace:on --linetrace:off -d:disable_libbacktrace
else
NIM_PARAMS := $(NIM_PARAMS) -d:release
endif

deps: | deps-common nat-libs beacon_chain.nims
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
endif

#- deletes and recreates "beacon_chain.nims" which on Windows is a copy instead of a proper symlink
update: | update-common
	rm -f beacon_chain.nims && \
		"$(MAKE)" beacon_chain.nims $(HANDLE_OUTPUT)

# symlink
beacon_chain.nims:
	ln -s beacon_chain.nimble $@

# nim-libbacktrace
libbacktrace:
	+ "$(MAKE)" -C vendor/nim-libbacktrace --no-print-directory BUILD_CXX_LIB=0

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
		$(ENV_SCRIPT) nim c -o:build/$@ $(NIM_PARAMS) "$${TOOL_DIR}/$@.nim" && \
		echo -e "Build completed successfully"

clean_eth2_network_simulation_data:
	rm -rf tests/simulation/data

clean_eth2_network_simulation_all:
	rm -rf tests/simulation/{data,validators}

GOERLI_TESTNETS_PARAMS := \
  --web3-url=$(GOERLI_WEB3_URL) \
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
		--log-level="$(LOG_LEVEL)" \
		--data-dir=build/data/$@_$(NODE_ID) \
		$(GOERLI_TESTNETS_PARAMS) $(NODE_PARAMS)

# Targets for backwards compatibility
beacon_node: | nimbus_beacon_node
	cp build/nimbus_beacon_node build/beacon_node

validator_client: | nimbus_validator_client
	cp build/nimbus_validator_client build/validator_client

signing_process: | nimbus_signing_process
	cp build/nimbus_signing_process build/signing_process

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
		--log-level="$(LOG_LEVEL)" \
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
		--log-level="$(LOG_LEVEL)" \
		--log-file=build/data/shared_$(1)_$(NODE_ID)/nbc_bn_$$(date +"%Y%m%d%H%M%S").log \
		--data-dir=build/data/shared_$(1)_$(NODE_ID) \
		--validators-dir=build/data/shared_$(1)_$(NODE_ID)/empty_dummy_folder \
		--secrets-dir=build/data/shared_$(1)_$(NODE_ID)/empty_dummy_folder \
		$(GOERLI_TESTNETS_PARAMS) $(NODE_PARAMS) &

	sleep 4

	build/nimbus_validator_client \
		--log-level="$(LOG_LEVEL)" \
		--log-file=build/data/shared_$(1)_$(NODE_ID)/nbc_vc_$$(date +"%Y%m%d%H%M%S").log \
		--data-dir=build/data/shared_$(1)_$(NODE_ID) \
		--rpc-port=$$(( $(BASE_RPC_PORT) +$(NODE_ID) ))
endef

define MAKE_DEPOSIT_DATA
	build/nimbus_beacon_node deposits create \
		--network=$(1) \
		--new-wallet-file=build/data/shared_$(1)_$(NODE_ID)/wallet.json \
		--out-validators-dir=build/data/shared_$(1)_$(NODE_ID)/validators \
		--out-secrets-dir=build/data/shared_$(1)_$(NODE_ID)/secrets \
		--out-deposits-file=$(1)-deposits_data-$$(date +"%Y%m%d%H%M%S").json \
		--count=$(VALIDATORS)
endef

define MAKE_DEPOSIT
	build/nimbus_beacon_node deposits create \
		--network=$(1) \
		--out-deposits-file=nbc-$(1)-deposits.json \
		--new-wallet-file=build/data/shared_$(1)_$(NODE_ID)/wallet.json \
		--out-validators-dir=build/data/shared_$(1)_$(NODE_ID)/validators \
		--out-secrets-dir=build/data/shared_$(1)_$(NODE_ID)/secrets \
		--count=$(VALIDATORS)

	build/deposit_contract sendDeposits \
		--web3-url=$(GOERLI_WEB3_URL) \
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
### pyrmont
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

ctail: | build deps
	mkdir -p vendor/.nimble/bin/
	$(ENV_SCRIPT) nim -d:danger -o:vendor/.nimble/bin/ctail c vendor/nim-chronicles-tail/ctail.nim

ntu: | build deps
	mkdir -p vendor/.nimble/bin/
	$(ENV_SCRIPT) nim -d:danger -o:vendor/.nimble/bin/ntu c vendor/nim-testutils/ntu.nim

clean: | clean-common
	rm -rf build/{$(TOOLS_CSV),all_tests,*_node,*ssz*,nimbus_beacon_node*,beacon_node_*,block_sim,state_sim,transition*}
ifneq ($(USE_LIBBACKTRACE), 0)
	+ "$(MAKE)" -C vendor/nim-libbacktrace clean $(HANDLE_OUTPUT)
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
		[[ -e "$@" ]] && mv "$@" build/ || true # workaround for https://github.com/nim-lang/Nim/issues/12745

book:
	cd docs/the_nimbus_book && \
	mdbook build

auditors-book:
	cd docs/the_auditors_handbook && \
	mdbook build

publish-book: | book auditors-book
	git branch -D gh-pages && \
	git branch --track gh-pages origin/gh-pages && \
	git worktree add tmp-book gh-pages && \
	rm -rf tmp-book/* && \
	mkdir -p tmp-book/auditors-book && \
	cp -a docs/the_nimbus_book/book/* tmp-book/ && \
	cp -a docs/the_auditors_handbook/book/* tmp-book/auditors-book/ && \
	cd tmp-book && \
	git add . && { \
		git commit -m "make publish-book" && \
		git push origin gh-pages || true; } && \
	cd .. && \
	git worktree remove -f tmp-book && \
	rm -rf tmp-book

#- we rebuild everything inside the container, so we need to clean up afterwards
dist:
	docker rm nimbus-eth2-dist $(HANDLE_OUTPUT) || true
	cd docker/dist && \
		DOCKER_BUILDKIT=1 docker build -t nimbus-eth2-dist --progress=plain --build-arg USER_ID=$$(id -u) --build-arg GROUP_ID=$$(id -g) . && \
		docker run --rm --name nimbus-eth2-dist -v $(CURDIR):/home/user/nimbus-eth2 nimbus-eth2-dist
	ls -l dist
	$(MAKE) clean

#- this simple test will show any missing dynamically-linked Glibc symbols in the target distro
dist-test:
	docker rm nimbus-eth2-dist-test $(HANDLE_OUTPUT) || true
	cd docker/dist && \
		for DISTRO in debian-bullseye; do \
			DOCKER_BUILDKIT=1 docker build -f Dockerfile.$${DISTRO} -t nimbus-eth2-dist-test --progress=plain --build-arg USER_ID=$$(id -u) --build-arg GROUP_ID=$$(id -g) . && \
			docker run --rm --name nimbus-eth2-dist-test -v $(CURDIR):/home/user/nimbus-eth2 nimbus-eth2-dist-test; \
		done

endif # "variables.mk" was not included
