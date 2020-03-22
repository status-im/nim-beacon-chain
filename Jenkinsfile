def runStages() {
	try {
		stage("Clone") {
			checkout scm
			sh "make build-system-checks || true"
		}

		cache(maxCacheSize: 250, caches: [
			[$class: "ArbitraryFileCache", excludes: "", includes: "**/*", path: "${WORKSPACE}/vendor/nimbus-build-system/vendor/Nim/bin"],
			[$class: "ArbitraryFileCache", excludes: "", includes: "**/*", path: "${WORKSPACE}/vendor/go/bin"],
			[$class: "ArbitraryFileCache", excludes: "", includes: "**/*", path: "${WORKSPACE}/jsonTestsCache"]
		]) {
			stage("Build") {
				sh "make -j${env.NPROC} update" /* to allow a newer Nim version to be detected */
				sh "make -j${env.NPROC} deps" /* to allow the following parallel stages */
				sh "scripts/setup_official_tests.sh jsonTestsCache"
			}
		}

		stage("Test") {
			parallel(
				"tools": {
					stage("Tools") {
						sh "make -j${env.NPROC}"
						sh "make -j${env.NPROC} LOG_LEVEL=TRACE NIMFLAGS='-d:testnet_servers_image'"
					}
				},
				"test suite": {
					stage("Test suite") {
						sh "make -j${env.NPROC} DISABLE_TEST_FIXTURES_SCRIPT=1 test"
					}
					if ("${NODE_NAME}" ==~ /linux.*/) {
						stage("testnet finalization") {
							sh "./scripts/launch_local_testnet.sh --testnet 0 --nodes 4 --disable-htop -- --verify-finalization --stop-at-epoch=5"
							sh "./scripts/launch_local_testnet.sh --testnet 1 --nodes 4 --disable-htop -- --verify-finalization --stop-at-epoch=5"
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
		cleanWs()
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

