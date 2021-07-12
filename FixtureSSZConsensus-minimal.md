FixtureSSZConsensus-minimal
===
## 
```diff
+ Rewards - all_balances_too_low_for_reward [Preset: minimal]                                OK
+ Rewards - duplicate_attestations_at_later_slots [Preset: minimal]                          OK
+ Rewards - empty [Preset: minimal]                                                          OK
+ Rewards - empty_leak [Preset: minimal]                                                     OK
+ Rewards - full_all_correct [Preset: minimal]                                               OK
+ Rewards - full_but_partial_participation [Preset: minimal]                                 OK
+ Rewards - full_but_partial_participation_leak [Preset: minimal]                            OK
+ Rewards - full_correct_target_incorrect_head [Preset: minimal]                             OK
+ Rewards - full_correct_target_incorrect_head_leak [Preset: minimal]                        OK
+ Rewards - full_delay_max_slots [Preset: minimal]                                           OK
+ Rewards - full_delay_one_slot [Preset: minimal]                                            OK
+ Rewards - full_half_correct_target_incorrect_head [Preset: minimal]                        OK
+ Rewards - full_half_correct_target_incorrect_head_leak [Preset: minimal]                   OK
+ Rewards - full_half_incorrect_target_correct_head [Preset: minimal]                        OK
+ Rewards - full_half_incorrect_target_correct_head_leak [Preset: minimal]                   OK
+ Rewards - full_half_incorrect_target_incorrect_head [Preset: minimal]                      OK
+ Rewards - full_half_incorrect_target_incorrect_head_leak [Preset: minimal]                 OK
+ Rewards - full_leak [Preset: minimal]                                                      OK
+ Rewards - full_mixed_delay [Preset: minimal]                                               OK
+ Rewards - full_random_0 [Preset: minimal]                                                  OK
+ Rewards - full_random_1 [Preset: minimal]                                                  OK
+ Rewards - full_random_2 [Preset: minimal]                                                  OK
+ Rewards - full_random_3 [Preset: minimal]                                                  OK
+ Rewards - full_random_five_epoch_leak [Preset: minimal]                                    OK
+ Rewards - full_random_leak [Preset: minimal]                                               OK
+ Rewards - full_random_low_balances_0 [Preset: minimal]                                     OK
+ Rewards - full_random_low_balances_1 [Preset: minimal]                                     OK
+ Rewards - full_random_misc_balances [Preset: minimal]                                      OK
+ Rewards - full_random_ten_epoch_leak [Preset: minimal]                                     OK
+ Rewards - half_full [Preset: minimal]                                                      OK
+ Rewards - half_full_leak [Preset: minimal]                                                 OK
+ Rewards - one_attestation_one_correct [Preset: minimal]                                    OK
+ Rewards - one_attestation_one_correct_leak [Preset: minimal]                               OK
+ Rewards - proposer_not_in_attestations [Preset: minimal]                                   OK
+ Rewards - quarter_full [Preset: minimal]                                                   OK
+ Rewards - quarter_full_leak [Preset: minimal]                                              OK
+ Rewards - some_very_low_effective_balances_that_attested [Preset: minimal]                 OK
+ Rewards - some_very_low_effective_balances_that_attested_leak [Preset: minimal]            OK
+ Rewards - some_very_low_effective_balances_that_did_not_attest [Preset: minimal]           OK
+ Rewards - some_very_low_effective_balances_that_did_not_attest_leak [Preset: minimal]      OK
+ Rewards - with_exited_validators [Preset: minimal]                                         OK
+ Rewards - with_exited_validators_leak [Preset: minimal]                                    OK
+ Rewards - with_not_yet_activated_validators [Preset: minimal]                              OK
+ Rewards - with_not_yet_activated_validators_leak [Preset: minimal]                         OK
+ Rewards - with_slashed_validators [Preset: minimal]                                        OK
+ Rewards - with_slashed_validators_leak [Preset: minimal]                                   OK
+ Slots - double_empty_epoch                                                                 OK
+ Slots - empty_epoch                                                                        OK
+ Slots - over_epoch_boundary                                                                OK
+ Slots - slots_1                                                                            OK
+ Slots - slots_2                                                                            OK
+ [Invalid]  bad_merkle_proof                                                                OK
+ [Invalid]  wrong_deposit_for_deposit_count                                                 OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - double_same_proposer_slashings_same_block OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - double_similar_proposer_slashings_same_bl OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - double_validator_exit_same_block [Preset: OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - duplicate_attester_slashing [Preset: mini OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - expected_deposit_in_block [Preset: minima OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - invalid_block_sig [Preset: minimal]       OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - invalid_proposer_index_sig_from_expected_ OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - invalid_proposer_index_sig_from_proposer_ OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - invalid_state_root [Preset: minimal]      OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - parent_from_same_slot [Preset: minimal]   OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - prev_slot_block_transition [Preset: minim OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - proposal_for_genesis_slot [Preset: minima OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - same_slot_block_transition [Preset: minim OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - slash_and_exit_same_index [Preset: minima OK
+ [Invalid] Official - Phase 0 - Sanity - Blocks - zero_block_sig [Preset: minimal]          OK
+ [Invalid] after_epoch_slots                                                                OK
+ [Invalid] all_empty_indices                                                                OK
+ [Invalid] att1_bad_extra_index                                                             OK
+ [Invalid] att1_bad_replaced_index                                                          OK
+ [Invalid] att1_duplicate_index_double_signed                                               OK
+ [Invalid] att1_duplicate_index_normal_signed                                               OK
+ [Invalid] att1_empty_indices                                                               OK
+ [Invalid] att1_high_index                                                                  OK
+ [Invalid] att2_bad_extra_index                                                             OK
+ [Invalid] att2_bad_replaced_index                                                          OK
+ [Invalid] att2_duplicate_index_double_signed                                               OK
+ [Invalid] att2_duplicate_index_normal_signed                                               OK
+ [Invalid] att2_empty_indices                                                               OK
+ [Invalid] att2_high_index                                                                  OK
+ [Invalid] bad_source_root                                                                  OK
+ [Invalid] before_inclusion_delay                                                           OK
+ [Invalid] correct_after_epoch_delay                                                        OK
+ [Invalid] empty_participants_seemingly_valid_sig                                           OK
+ [Invalid] empty_participants_zeroes_sig                                                    OK
+ [Invalid] epochs_are_different                                                             OK
+ [Invalid] future_target_epoch                                                              OK
+ [Invalid] headers_are_same_sigs_are_different                                              OK
+ [Invalid] headers_are_same_sigs_are_same                                                   OK
+ [Invalid] incorrect_head_after_epoch_delay                                                 OK
+ [Invalid] incorrect_head_and_target_after_epoch_delay                                      OK
+ [Invalid] incorrect_target_after_epoch_delay                                               OK
+ [Invalid] invalid_attestation_signature                                                    OK
+ [Invalid] invalid_current_source_root                                                      OK
+ [Invalid] invalid_different_proposer_indices                                               OK
+ [Invalid] invalid_index                                                                    OK
+ [Invalid] invalid_multiple_blocks_single_slot                                              OK
+ [Invalid] invalid_parent_root                                                              OK
+ [Invalid] invalid_proposer_index                                                           OK
+ [Invalid] invalid_sig_1                                                                    OK
+ [Invalid] invalid_sig_1_and_2                                                              OK
+ [Invalid] invalid_sig_1_and_2_swap                                                         OK
+ [Invalid] invalid_sig_2                                                                    OK
+ [Invalid] invalid_signature                                                                OK
+ [Invalid] invalid_slot_block_header                                                        OK
+ [Invalid] mismatched_target_and_slot                                                       OK
+ [Invalid] new_source_epoch                                                                 OK
+ [Invalid] no_double_or_surround                                                            OK
+ [Invalid] old_source_epoch                                                                 OK
+ [Invalid] old_target_epoch                                                                 OK
+ [Invalid] participants_already_slashed                                                     OK
+ [Invalid] proposer_is_not_activated                                                        OK
+ [Invalid] proposer_is_slashed                                                              OK
+ [Invalid] proposer_is_withdrawn                                                            OK
+ [Invalid] proposer_slashed                                                                 OK
+ [Invalid] same_data                                                                        OK
+ [Invalid] source_root_is_target_root                                                       OK
+ [Invalid] too_few_aggregation_bits                                                         OK
+ [Invalid] too_many_aggregation_bits                                                        OK
+ [Invalid] unsorted_att_1                                                                   OK
+ [Invalid] unsorted_att_2                                                                   OK
+ [Invalid] validator_already_exited                                                         OK
+ [Invalid] validator_exit_in_future                                                         OK
+ [Invalid] validator_invalid_validator_index                                                OK
+ [Invalid] validator_not_active                                                             OK
+ [Invalid] validator_not_active_long_enough                                                 OK
+ [Invalid] wrong_index_for_committee_signature                                              OK
+ [Invalid] wrong_index_for_slot_0                                                           OK
+ [Invalid] wrong_index_for_slot_1                                                           OK
+ [Valid]    invalid_sig_new_deposit                                                         OK
+ [Valid]    invalid_sig_other_version                                                       OK
+ [Valid]    invalid_sig_top_up                                                              OK
+ [Valid]    invalid_withdrawal_credentials_top_up                                           OK
+ [Valid]    new_deposit_eth1_withdrawal_credentials                                         OK
+ [Valid]    new_deposit_max                                                                 OK
+ [Valid]    new_deposit_non_versioned_withdrawal_credentials                                OK
+ [Valid]    new_deposit_over_max                                                            OK
+ [Valid]    new_deposit_under_max                                                           OK
+ [Valid]    success_top_up                                                                  OK
+ [Valid]    valid_sig_but_forked_state                                                      OK
+ [Valid]   Official - Phase 0 - Finality - finality_no_updates_at_genesis [Preset: minimal] OK
+ [Valid]   Official - Phase 0 - Finality - finality_rule_1 [Preset: minimal]                OK
+ [Valid]   Official - Phase 0 - Finality - finality_rule_2 [Preset: minimal]                OK
+ [Valid]   Official - Phase 0 - Finality - finality_rule_3 [Preset: minimal]                OK
+ [Valid]   Official - Phase 0 - Finality - finality_rule_4 [Preset: minimal]                OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - attestation [Preset: minimal]             OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - attester_slashing [Preset: minimal]       OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - balance_driven_status_transitions [Preset OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - deposit_in_block [Preset: minimal]        OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - deposit_top_up [Preset: minimal]          OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - empty_block_transition [Preset: minimal]  OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - empty_block_transition_large_validator_se OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - empty_epoch_transition [Preset: minimal]  OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - empty_epoch_transition_large_validator_se OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - empty_epoch_transition_not_finalizing [Pr OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - full_random_operations_0 [Preset: minimal OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - full_random_operations_1 [Preset: minimal OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - full_random_operations_2 [Preset: minimal OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - full_random_operations_3 [Preset: minimal OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - high_proposer_index [Preset: minimal]     OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - historical_batch [Preset: minimal]        OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - multiple_attester_slashings_no_overlap [P OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - multiple_attester_slashings_partial_overl OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - multiple_different_proposer_slashings_sam OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - multiple_different_validator_exits_same_b OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - proposer_after_inactive_index [Preset: mi OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - proposer_self_slashing [Preset: minimal]  OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - proposer_slashing [Preset: minimal]       OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - skipped_slots [Preset: minimal]           OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - slash_and_exit_diff_index [Preset: minima OK
+ [Valid]   Official - Phase 0 - Sanity - Blocks - voluntary_exit [Preset: minimal]          OK
+ [Valid]   correct_epoch_delay                                                              OK
+ [Valid]   correct_min_inclusion_delay                                                      OK
+ [Valid]   correct_sqrt_epoch_delay                                                         OK
+ [Valid]   default_exit_epoch_subsequent_exit                                               OK
+ [Valid]   incorrect_head_and_target_epoch_delay                                            OK
+ [Valid]   incorrect_head_and_target_min_inclusion_delay                                    OK
+ [Valid]   incorrect_head_and_target_sqrt_epoch_delay                                       OK
+ [Valid]   incorrect_head_epoch_delay                                                       OK
+ [Valid]   incorrect_head_min_inclusion_delay                                               OK
+ [Valid]   incorrect_head_sqrt_epoch_delay                                                  OK
+ [Valid]   incorrect_target_epoch_delay                                                     OK
+ [Valid]   incorrect_target_min_inclusion_delay                                             OK
+ [Valid]   incorrect_target_sqrt_epoch_delay                                                OK
+ [Valid]   success                                                                          OK
+ [Valid]   success_already_exited_long_ago                                                  OK
+ [Valid]   success_already_exited_recent                                                    OK
+ [Valid]   success_attestation_from_future                                                  OK
+ [Valid]   success_block_header                                                             OK
+ [Valid]   success_block_header_from_future                                                 OK
+ [Valid]   success_double                                                                   OK
+ [Valid]   success_exit_queue                                                               OK
+ [Valid]   success_low_balances                                                             OK
+ [Valid]   success_misc_balances                                                            OK
+ [Valid]   success_multi_proposer_index_iterations                                          OK
+ [Valid]   success_previous_epoch                                                           OK
+ [Valid]   success_proposer_index_slashed                                                   OK
+ [Valid]   success_slashed_and_proposer_index_the_same                                      OK
+ [Valid]   success_surround                                                                 OK
+ [Valid]   success_with_effective_balance_disparity                                         OK
```
OK: 202/202 Fail: 0/202 Skip: 0/202
## Official - Altair - SSZ consensus objects  [Preset: minimal]
```diff
+   Testing    AggregateAndProof                                                             OK
+   Testing    Attestation                                                                   OK
+   Testing    AttestationData                                                               OK
+   Testing    AttesterSlashing                                                              OK
+   Testing    BeaconBlock                                                                   OK
+   Testing    BeaconBlockBody                                                               OK
+   Testing    BeaconBlockHeader                                                             OK
+   Testing    BeaconState                                                                   OK
+   Testing    Checkpoint                                                                    OK
+   Testing    ContributionAndProof                                                          OK
+   Testing    Deposit                                                                       OK
+   Testing    DepositData                                                                   OK
+   Testing    DepositMessage                                                                OK
+   Testing    Eth1Block                                                                     OK
+   Testing    Eth1Data                                                                      OK
+   Testing    Fork                                                                          OK
+   Testing    ForkData                                                                      OK
+   Testing    HistoricalBatch                                                               OK
+   Testing    IndexedAttestation                                                            OK
+   Testing    LightClientSnapshot                                                           OK
+   Testing    LightClientUpdate                                                             OK
+   Testing    PendingAttestation                                                            OK
+   Testing    ProposerSlashing                                                              OK
+   Testing    SignedAggregateAndProof                                                       OK
+   Testing    SignedBeaconBlock                                                             OK
+   Testing    SignedBeaconBlockHeader                                                       OK
+   Testing    SignedContributionAndProof                                                    OK
+   Testing    SignedVoluntaryExit                                                           OK
+   Testing    SigningData                                                                   OK
+   Testing    SyncAggregate                                                                 OK
+   Testing    SyncAggregatorSelectionData                                                   OK
+   Testing    SyncCommittee                                                                 OK
+   Testing    SyncCommitteeContribution                                                     OK
+   Testing    SyncCommitteeMessage                                                          OK
+   Testing    Validator                                                                     OK
+   Testing    VoluntaryExit                                                                 OK
```
OK: 36/36 Fail: 0/36 Skip: 0/36
## Official - Phase 0 - Epoch Processing - Effective balance updates [Preset: minimal]
```diff
+ Effective balance updates - effective_balance_hysteresis [Preset: minimal]                 OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## Official - Phase 0 - Epoch Processing - Eth1 data reset [Preset: minimal]
```diff
+ Eth1 data reset - eth1_vote_no_reset [Preset: minimal]                                     OK
+ Eth1 data reset - eth1_vote_reset [Preset: minimal]                                        OK
```
OK: 2/2 Fail: 0/2 Skip: 0/2
## Official - Phase 0 - Epoch Processing - Historical roots update [Preset: minimal]
```diff
+ Historical roots update - historical_root_accumulator [Preset: minimal]                    OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## Official - Phase 0 - Epoch Processing - Justification & Finalization [Preset: minimal]
```diff
+ Justification & Finalization - 123_ok_support [Preset: minimal]                            OK
+ Justification & Finalization - 123_poor_support [Preset: minimal]                          OK
+ Justification & Finalization - 12_ok_support [Preset: minimal]                             OK
+ Justification & Finalization - 12_ok_support_messed_target [Preset: minimal]               OK
+ Justification & Finalization - 12_poor_support [Preset: minimal]                           OK
+ Justification & Finalization - 234_ok_support [Preset: minimal]                            OK
+ Justification & Finalization - 234_poor_support [Preset: minimal]                          OK
+ Justification & Finalization - 23_ok_support [Preset: minimal]                             OK
+ Justification & Finalization - 23_poor_support [Preset: minimal]                           OK
```
OK: 9/9 Fail: 0/9 Skip: 0/9
## Official - Phase 0 - Epoch Processing - Participation record updates [Preset: minimal]
```diff
+ Participation record updates - updated_participation_record [Preset: minimal]              OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## Official - Phase 0 - Epoch Processing - RANDAO mixes reset [Preset: minimal]
```diff
+ RANDAO mixes reset - updated_randao_mixes [Preset: minimal]                                OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## Official - Phase 0 - Epoch Processing - Registry updates [Preset: minimal]
```diff
+ Registry updates - activation_queue_activation_and_ejection [Preset: minimal]              OK
+ Registry updates - activation_queue_efficiency [Preset: minimal]                           OK
+ Registry updates - activation_queue_no_activation_no_finality [Preset: minimal]            OK
+ Registry updates - activation_queue_sorting [Preset: minimal]                              OK
+ Registry updates - activation_queue_to_activated_if_finalized [Preset: minimal]            OK
+ Registry updates - add_to_activation_queue [Preset: minimal]                               OK
+ Registry updates - ejection [Preset: minimal]                                              OK
+ Registry updates - ejection_past_churn_limit [Preset: minimal]                             OK
```
OK: 8/8 Fail: 0/8 Skip: 0/8
## Official - Phase 0 - Epoch Processing - Slashings [Preset: minimal]
```diff
+ Slashings - low_penalty [Preset: minimal]                                                  OK
+ Slashings - max_penalties [Preset: minimal]                                                OK
+ Slashings - minimal_penalty [Preset: minimal]                                              OK
+ Slashings - scaled_penalties [Preset: minimal]                                             OK
```
OK: 4/4 Fail: 0/4 Skip: 0/4
## Official - Phase 0 - Epoch Processing - Slashings reset [Preset: minimal]
```diff
+ Slashings reset - flush_slashings [Preset: minimal]                                        OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## Official - Phase 0 - SSZ consensus objects  [Preset: minimal]
```diff
+   Testing    AggregateAndProof                                                             OK
+   Testing    Attestation                                                                   OK
+   Testing    AttestationData                                                               OK
+   Testing    AttesterSlashing                                                              OK
+   Testing    BeaconBlock                                                                   OK
+   Testing    BeaconBlockBody                                                               OK
+   Testing    BeaconBlockHeader                                                             OK
+   Testing    BeaconState                                                                   OK
+   Testing    Checkpoint                                                                    OK
+   Testing    Deposit                                                                       OK
+   Testing    DepositData                                                                   OK
+   Testing    DepositMessage                                                                OK
+   Testing    Eth1Block                                                                     OK
+   Testing    Eth1Data                                                                      OK
+   Testing    Fork                                                                          OK
+   Testing    ForkData                                                                      OK
+   Testing    HistoricalBatch                                                               OK
+   Testing    IndexedAttestation                                                            OK
+   Testing    PendingAttestation                                                            OK
+   Testing    ProposerSlashing                                                              OK
+   Testing    SignedAggregateAndProof                                                       OK
+   Testing    SignedBeaconBlock                                                             OK
+   Testing    SignedBeaconBlockHeader                                                       OK
+   Testing    SignedVoluntaryExit                                                           OK
+   Testing    SigningData                                                                   OK
+   Testing    Validator                                                                     OK
+   Testing    VoluntaryExit                                                                 OK
```
OK: 27/27 Fail: 0/27 Skip: 0/27

---TOTAL---
OK: 293/293 Fail: 0/293 Skip: 0/293
