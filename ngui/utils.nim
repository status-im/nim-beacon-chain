{.push raises: [Defect].}

import
  stew/byteutils,

  ../beacon_chain/spec/[crypto, datatypes, digest]

func toDisplayHex*(v: openArray[byte]): string =
  "<pre>0x" & toHex(v) & "</pre>"

func toDisplayHex*(v: Eth2Digest): string = toDisplayHex(v.data)
func toDisplayHex*(v: ValidatorSig | TrustedSig): string = toDisplayHex(toRaw(v))

func toBlockLink*(v: Eth2Digest): string =
  let
    display = toDisplayHex(v)
    target = "0x" & toHex(v.data)

  "<a href='block://" & target & "'>" & display & "</a>"

func toValidatorLink*(v: ValidatorIndex): string =
  "<a href='validator://" & $v & "'>" & $v & "</a>"
