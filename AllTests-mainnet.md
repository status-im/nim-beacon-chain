AllTests-mainnet
===
## Attestation pool processing [Preset: mainnet]
```diff
+ Attestations may arrive in any order [Preset: mainnet]                                     OK
+ Attestations may overlap, bigger first [Preset: mainnet]                                   OK
+ Attestations may overlap, smaller first [Preset: mainnet]                                  OK
+ Attestations should be combined [Preset: mainnet]                                          OK
+ Can add and retrieve simple attestation [Preset: mainnet]                                  OK
+ Fork choice returns block with attestation                                                 OK
+ Fork choice returns latest block with no attestations                                      OK
+ Trying to add a block twice tags the second as an error                                    OK
+ Trying to add a duplicate block from an old pruned epoch is tagged as an error             OK
```
OK: 9/9 Fail: 0/9 Skip: 0/9
## Attestation validation  [Preset: mainnet]
```diff
+ Validation sanity                                                                          OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## Beacon chain DB [Preset: mainnet]
```diff
+ empty database [Preset: mainnet]                                                           OK
+ find ancestors [Preset: mainnet]                                                           OK
+ sanity check blocks [Preset: mainnet]                                                      OK
+ sanity check genesis roundtrip [Preset: mainnet]                                           OK
+ sanity check states [Preset: mainnet]                                                      OK
```
OK: 5/5 Fail: 0/5 Skip: 0/5
## Beacon node
```diff
+ Compile                                                                                    OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## Beacon state [Preset: mainnet]
```diff
+ Smoke test initialize_beacon_state_from_eth1 [Preset: mainnet]                             OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## Block pool processing [Preset: mainnet]
```diff
+ Adding the same block twice returns a Duplicate error [Preset: mainnet]                    OK
+ Reverse order block add & get [Preset: mainnet]                                            OK
+ Simple block add&get [Preset: mainnet]                                                     OK
+ getRef returns nil for missing blocks                                                      OK
+ loadTailState gets genesis block on first load [Preset: mainnet]                           OK
+ updateHead updates head and headState [Preset: mainnet]                                    OK
+ updateStateData sanity [Preset: mainnet]                                                   OK
```
OK: 7/7 Fail: 0/7 Skip: 0/7
## Block processing [Preset: mainnet]
```diff
+ Attestation gets processed at epoch [Preset: mainnet]                                      OK
+ Passes from genesis state, empty block [Preset: mainnet]                                   OK
+ Passes from genesis state, no block [Preset: mainnet]                                      OK
+ Passes through epoch update, empty block [Preset: mainnet]                                 OK
+ Passes through epoch update, no block [Preset: mainnet]                                    OK
```
OK: 5/5 Fail: 0/5 Skip: 0/5
## BlockRef and helpers [Preset: mainnet]
```diff
+ epochAncestor sanity [Preset: mainnet]                                                     OK
+ get_ancestor sanity [Preset: mainnet]                                                      OK
+ isAncestorOf sanity [Preset: mainnet]                                                      OK
```
OK: 3/3 Fail: 0/3 Skip: 0/3
## BlockSlot and helpers [Preset: mainnet]
```diff
+ atSlot sanity [Preset: mainnet]                                                            OK
+ parent sanity [Preset: mainnet]                                                            OK
```
OK: 2/2 Fail: 0/2 Skip: 0/2
## Fork Choice + Finality  [Preset: mainnet]
```diff
+ fork_choice - testing finality #01                                                         OK
+ fork_choice - testing finality #02                                                         OK
+ fork_choice - testing no votes                                                             OK
+ fork_choice - testing with votes                                                           OK
```
OK: 4/4 Fail: 0/4 Skip: 0/4
## Honest validator
```diff
+ General pubsub topics:                                                                     OK
+ Mainnet attestation topics                                                                 OK
```
OK: 2/2 Fail: 0/2 Skip: 0/2
## Interop
```diff
+ Interop genesis                                                                            OK
+ Interop signatures                                                                         OK
+ Mocked start private key                                                                   OK
```
OK: 3/3 Fail: 0/3 Skip: 0/3
## Keystore
```diff
+ Pbkdf2 decryption                                                                          OK
+ Pbkdf2 encryption                                                                          OK
+ Pbkdf2 errors                                                                              OK
+ Scrypt decryption                                                                          OK
+ Scrypt encryption                                                                          OK
```
OK: 5/5 Fail: 0/5 Skip: 0/5
## Mocking utilities
```diff
+ merkle_minimal                                                                             OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## Official - constants & config  [Preset: mainnet]
```diff
+ BASE_REWARD_FACTOR                                64                   [Preset: mainnet]   OK
+ BLS_WITHDRAWAL_PREFIX                             "0x00"               [Preset: mainnet]   OK
+ CHURN_LIMIT_QUOTIENT                              65536                [Preset: mainnet]   OK
  DEPOSIT_CHAIN_ID                                  1                    [Preset: mainnet]   Skip
  DEPOSIT_CONTRACT_ADDRESS                          "0x1234567890123456789012345678901234567 Skip
  DEPOSIT_NETWORK_ID                                1                    [Preset: mainnet]   Skip
+ DOMAIN_AGGREGATE_AND_PROOF                        "0x06000000"         [Preset: mainnet]   OK
+ DOMAIN_BEACON_ATTESTER                            "0x01000000"         [Preset: mainnet]   OK
+ DOMAIN_BEACON_PROPOSER                            "0x00000000"         [Preset: mainnet]   OK
+ DOMAIN_DEPOSIT                                    "0x03000000"         [Preset: mainnet]   OK
+ DOMAIN_RANDAO                                     "0x02000000"         [Preset: mainnet]   OK
+ DOMAIN_SELECTION_PROOF                            "0x05000000"         [Preset: mainnet]   OK
+ DOMAIN_VOLUNTARY_EXIT                             "0x04000000"         [Preset: mainnet]   OK
+ EFFECTIVE_BALANCE_INCREMENT                       1000000000           [Preset: mainnet]   OK
+ EJECTION_BALANCE                                  16000000000          [Preset: mainnet]   OK
+ EPOCHS_PER_ETH1_VOTING_PERIOD                     32                   [Preset: mainnet]   OK
+ EPOCHS_PER_HISTORICAL_VECTOR                      65536                [Preset: mainnet]   OK
+ EPOCHS_PER_RANDOM_SUBNET_SUBSCRIPTION             256                  [Preset: mainnet]   OK
+ EPOCHS_PER_SLASHINGS_VECTOR                       8192                 [Preset: mainnet]   OK
+ ETH1_FOLLOW_DISTANCE                              1024                 [Preset: mainnet]   OK
  GENESIS_DELAY                                     172800               [Preset: mainnet]   Skip
  GENESIS_FORK_VERSION                              "0x00000000"         [Preset: mainnet]   Skip
+ HISTORICAL_ROOTS_LIMIT                            16777216             [Preset: mainnet]   OK
+ HYSTERESIS_DOWNWARD_MULTIPLIER                    1                    [Preset: mainnet]   OK
+ HYSTERESIS_QUOTIENT                               4                    [Preset: mainnet]   OK
+ HYSTERESIS_UPWARD_MULTIPLIER                      5                    [Preset: mainnet]   OK
+ INACTIVITY_PENALTY_QUOTIENT                       16777216             [Preset: mainnet]   OK
+ MAX_ATTESTATIONS                                  128                  [Preset: mainnet]   OK
+ MAX_ATTESTER_SLASHINGS                            2                    [Preset: mainnet]   OK
+ MAX_COMMITTEES_PER_SLOT                           64                   [Preset: mainnet]   OK
+ MAX_DEPOSITS                                      16                   [Preset: mainnet]   OK
+ MAX_EFFECTIVE_BALANCE                             32000000000          [Preset: mainnet]   OK
+ MAX_EPOCHS_PER_CROSSLINK                          64                   [Preset: mainnet]   OK
+ MAX_PROPOSER_SLASHINGS                            16                   [Preset: mainnet]   OK
+ MAX_SEED_LOOKAHEAD                                4                    [Preset: mainnet]   OK
+ MAX_VALIDATORS_PER_COMMITTEE                      2048                 [Preset: mainnet]   OK
+ MAX_VOLUNTARY_EXITS                               16                   [Preset: mainnet]   OK
+ MIN_ATTESTATION_INCLUSION_DELAY                   1                    [Preset: mainnet]   OK
+ MIN_DEPOSIT_AMOUNT                                1000000000           [Preset: mainnet]   OK
+ MIN_EPOCHS_TO_INACTIVITY_PENALTY                  4                    [Preset: mainnet]   OK
  MIN_GENESIS_ACTIVE_VALIDATOR_COUNT                16384                [Preset: mainnet]   Skip
  MIN_GENESIS_TIME                                  1578009600           [Preset: mainnet]   Skip
+ MIN_PER_EPOCH_CHURN_LIMIT                         4                    [Preset: mainnet]   OK
+ MIN_SEED_LOOKAHEAD                                1                    [Preset: mainnet]   OK
+ MIN_SLASHING_PENALTY_QUOTIENT                     32                   [Preset: mainnet]   OK
+ MIN_VALIDATOR_WITHDRAWABILITY_DELAY               256                  [Preset: mainnet]   OK
+ PROPOSER_REWARD_QUOTIENT                          8                    [Preset: mainnet]   OK
+ RANDOM_SUBNETS_PER_VALIDATOR                      1                    [Preset: mainnet]   OK
+ SAFE_SLOTS_TO_UPDATE_JUSTIFIED                    8                    [Preset: mainnet]   OK
+ SECONDS_PER_ETH1_BLOCK                            14                   [Preset: mainnet]   OK
+ SECONDS_PER_SLOT                                  12                   [Preset: mainnet]   OK
+ SHARD_COMMITTEE_PERIOD                            256                  [Preset: mainnet]   OK
+ SHUFFLE_ROUND_COUNT                               90                   [Preset: mainnet]   OK
+ SLOTS_PER_EPOCH                                   32                   [Preset: mainnet]   OK
+ SLOTS_PER_HISTORICAL_ROOT                         8192                 [Preset: mainnet]   OK
+ TARGET_AGGREGATORS_PER_COMMITTEE                  16                   [Preset: mainnet]   OK
+ TARGET_COMMITTEE_SIZE                             128                  [Preset: mainnet]   OK
+ VALIDATOR_REGISTRY_LIMIT                          1099511627776        [Preset: mainnet]   OK
+ WHISTLEBLOWER_REWARD_QUOTIENT                     512                  [Preset: mainnet]   OK
```
OK: 52/59 Fail: 0/59 Skip: 7/59
## PeerPool testing suite
```diff
+ Access peers by key test                                                                   OK
+ Acquire from empty pool                                                                    OK
+ Acquire/Sorting and consistency test                                                       OK
+ Iterators test                                                                             OK
+ Peer lifetime test                                                                         OK
+ Safe/Clear test                                                                            OK
+ Score check test                                                                           OK
+ addPeer() test                                                                             OK
+ addPeerNoWait() test                                                                       OK
+ deletePeer() test                                                                          OK
```
OK: 10/10 Fail: 0/10 Skip: 0/10
## SSZ dynamic navigator
```diff
+ navigating fields                                                                          OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## SSZ navigator
```diff
+ basictype                                                                                  OK
+ lists with max size                                                                        OK
+ simple object fields                                                                       OK
```
OK: 3/3 Fail: 0/3 Skip: 0/3
## Spec datatypes
```diff
+ Graffiti bytes                                                                             OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## Spec helpers
```diff
+ integer_squareroot                                                                         OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## Sync protocol
```diff
+ Compile                                                                                    OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## Zero signature sanity checks
```diff
+ SSZ serialization roundtrip of SignedBeaconBlockHeader                                     OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## [Unit - Spec - Block processing] Attestations  [Preset: mainnet]
```diff
+ Valid attestation                                                                          OK
+ Valid attestation from previous epoch                                                      OK
```
OK: 2/2 Fail: 0/2 Skip: 0/2
## [Unit - Spec - Block processing] Deposits  [Preset: mainnet]
```diff
+ Deposit at MAX_EFFECTIVE_BALANCE balance (32 ETH)                                          OK
+ Deposit over MAX_EFFECTIVE_BALANCE balance (32 ETH)                                        OK
+ Deposit under MAX_EFFECTIVE_BALANCE balance (32 ETH)                                       OK
+ Invalid deposit at MAX_EFFECTIVE_BALANCE balance (32 ETH)                                  OK
+ Validator top-up                                                                           OK
```
OK: 5/5 Fail: 0/5 Skip: 0/5
## [Unit - Spec - Epoch processing] Justification and Finalization  [Preset: mainnet]
```diff
+  Rule I - 234 finalization with enough support                                             OK
+  Rule I - 234 finalization without support                                                 OK
+  Rule II - 23 finalization with enough support                                             OK
+  Rule II - 23 finalization without support                                                 OK
+  Rule III - 123 finalization with enough support                                           OK
+  Rule III - 123 finalization without support                                               OK
+  Rule IV - 12 finalization with enough support                                             OK
+  Rule IV - 12 finalization without support                                                 OK
```
OK: 8/8 Fail: 0/8 Skip: 0/8
## chain DAG finalization tests [Preset: mainnet]
```diff
+ init with gaps [Preset: mainnet]                                                           OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## hash
```diff
+ HashArray                                                                                  OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1

---TOTAL---
OK: 136/143 Fail: 0/143 Skip: 7/143
