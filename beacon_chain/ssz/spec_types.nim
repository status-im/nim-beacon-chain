import
  typetraits,
  ../spec/[crypto, digest]

# Eth2-spec-specific type handling that is not generic to SSZ

template toSszType*(x: auto): auto =
  mixin toSszType

  # Please note that BitArray doesn't need any special treatment here
  # because it can be considered a regular fixed-size object type.

  # enum should not be added here as nim will raise Defect when value is out
  # of range
  when x is Slot|Epoch: uint64(x)
  elif x is Eth2Digest: x.data
  elif x is BlsCurveType: toRaw(x)
  elif x is ForkDigest|Version|GraffitiBytes: distinctBase(x)
  else: x
