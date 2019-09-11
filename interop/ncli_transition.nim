import
  confutils, chronicles,
  ../beacon_chain/spec/[beaconstate, crypto, datatypes, digest, helpers, validator],
  ../beacon_chain/[extras, state_transition, ssz]

cli do(pre: string, blck: string, post: string, verifyStateRoot = false):
  let
    stateX = SSZ.loadFile(pre, BeaconState)
    blckX = SSZ.loadFile(blck, BeaconBlock)
    flags = if verifyStateRoot: {skipValidation} else: {}

  var stateY = HashedBeaconState(data: stateX, root: hash_tree_root(stateX))
  if not state_transition(stateY, blckX, flags):
    error "State transition failed"

  SSZ.saveFile(post, stateY.data)
