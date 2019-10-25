import
  confutils, ospaths, strutils, chronicles, json_serialization,
  nimcrypto/utils,
  ../beacon_chain/spec/[crypto, datatypes, digest],
  ../beacon_chain/[ssz]

# TODO turn into arguments
cli do(kind: string, file: string):

  template printit(t: untyped) {.dirty.} =
      let v =
        if cmpIgnoreCase(ext, ".ssz") == 0:
          SSZ.loadFile(file, t)
        elif cmpIgnoreCase(ext, ".json") == 0:
          JSON.loadFile(file, t)
        else:
          echo "Unknown file type: ", ext
          quit 1

      echo hash_tree_root(v).data.toHex(true)

  let ext = splitFile(file).ext

  case kind
  of "attester_slashing": printit(AttesterSlashing)
  of "attestation": printit(Attestation)
  of "block": printit(BeaconBlock)
  of "block_body": printit(BeaconBlockBody)
  of "block_header": printit(BeaconBlockHeader)
  of "deposit": printit(Deposit)
  of "deposit_data": printit(DepositData)
  of "eth1_data": printit(Eth1Data)
  of "state": printit(BeaconState)
  of "proposer_slashing": printit(ProposerSlashing)
  of "transfer": printit(Transfer)
  of "voluntary_exit": printit(VoluntaryExit)
