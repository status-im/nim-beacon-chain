# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Temporary dumping ground for extra types and helpers that could make it into
# the spec potentially

# TOdO

type
  UpdateFlag* = enum
    skipValidation ##\
    ## The `skipValidation` flag is used to skip over certain checks that are
    ## normally done when an untrusted block arrives from the network. The
    ## primary use case for this flag is when a proposer must propose a new
    ## block - in order to do so, it needs to update the state as if the block
    ## was valid, before it can sign it.

  UpdateFlags* = set[UpdateFlag]
