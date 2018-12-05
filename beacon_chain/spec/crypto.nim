# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# At the time of writing, the exact definitions of what should be used for
# cryptography in the spec is in flux, with sizes and test vectors still being
# hashed out. This layer helps isolate those chagnes.

import
  milagro_crypto, hashes

type
  ValidatorPubKey* = milagro_crypto.VerKey
  ValidatorPrivKey* = milagro_crypto.SigKey
  ValidatorSig* = milagro_crypto.Signature

template hash*(k: ValidatorPubKey|ValidatorPrivKey): Hash =
  hash(k.getRaw)

proc pubKey*(pk: ValidatorPrivKey): ValidatorPubKey = fromSigKey(pk)

