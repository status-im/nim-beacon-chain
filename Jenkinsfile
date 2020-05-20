def runStages() {
	try {
		stage("Clone") {
			checkout scm
			/* we need to update the submodules before caching kicks in */
			sh "git submodule update --init --recursive"
		}

		cache(maxCacheSize: 250, caches: [
			[$class: "ArbitraryFileCache", excludes: "", includes: "**/*", path: "${WORKSPACE}/vendor/nimbus-build-system/vendor/Nim/bin"],
			[$class: "ArbitraryFileCache", excludes: "", includes: "**/*", path: "${WORKSPACE}/jsonTestsCache"]
		]) {
			stage("Build") {
				sh """#!/bin/bash
				make -j${env.NPROC} update # to allow a newer Nim version to be detected
				make -j${env.NPROC} deps # to allow the following parallel stages
				V=1 ./scripts/setup_official_tests.sh jsonTestsCache
				"""
			}
		}

		stage("Test") {
			parallel(
				"tools": {
					stage("Tools") {
						sh """#!/bin/bash
						make -j${env.NPROC}
						make -j${env.NPROC} LOG_LEVEL=TRACE NIMFLAGS='-d:testnet_servers_image'
						"""
					}
				},
				"test suite": {
					stage("Test suite") {
						sh "make -j${env.NPROC} DISABLE_TEST_FIXTURES_SCRIPT=1 test"
					}
					if ("${NODE_NAME}" ==~ /linux.*/) {
						stage("testnet finalization") {
							// EXECUTOR_NUMBER will be 0 or 1, since we have 2 executors per Jenkins node
							sh """#!/bin/bash
							timeout -k 20s 10m ./scripts/launch_local_testnet.sh --testnet 0 --nodes 4 --log-level INFO --disable-htop --base-port \$(( 9000 + EXECUTOR_NUMBER * 100 )) --base-metrics-port \$(( 8008 + EXECUTOR_NUMBER * 100 )) -- --verify-finalization --stop-at-epoch=5
							timeout -k 20s 40m ./scripts/launch_local_testnet.sh --testnet 1 --nodes 4 --log-level INFO --disable-htop --base-port \$(( 9000 + EXECUTOR_NUMBER * 100 )) --base-metrics-port \$(( 8008 + EXECUTOR_NUMBER * 100 )) -- --verify-finalization --stop-at-epoch=5
							"""
						}
					}
				}
			)
		}
	} catch(e) {
		echo "'${env.STAGE_NAME}' stage failed"
		// we need to rethrow the exception here
		throw e
	} finally {
		cleanWs(disableDeferredWipeout: true, deleteDirs: true)
	}
}

parallel(
	"Linux": {
		node("linux") {
			withEnv(["NPROC=${sh(returnStdout: true, script: 'nproc').trim()}"]) {
				runStages()
			}
		}
	},
	"macOS": {
		node("macos") {
			withEnv(["NPROC=${sh(returnStdout: true, script: 'sysctl -n hw.logicalcpu').trim()}"]) {
				runStages()
			}
		}
	}
)

