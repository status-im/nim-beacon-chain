# Nimbus Beacon Chain

https://github.com/status-im/nim-beacon-chain

Nimbus Beacon Chain (NBC) is an implementation of an Ethereum 2 client.

## Audit scope

### Network Core (leveraging the libp2p framework)

| Sub-topic                              |
| -------------------------------------- |
| Discovery Protocol (discv5)            |
| Publish/Subscribe protocol             |
| Eth2 Request/Response protocol         |
| SSZ - (De)serialization & tree hashing |
| Wire encryption                        |

### ETH2 Specification core

| Sub-topic                             |
| ------------------------------------- |
| State transition logic                |
| Signature verification                |
| Epoch finalisation and justification  |
| Reward processing                     |
| Eth1 data processing                  |
| Fork choice logic                     |
| Block processing and production       |
| Attestation processing and production |
| Block synchronization                 |
| Peer pool management                  |

### Validator core and user experience

| Sub-topic                         |
| --------------------------------- |
| Block/attestation signing         |
| Slash-prevention mechanisms       |
| RPC API                           |
| Accounts management & key storage |
| Command Line Interface (CLI)      |

## High-level view of the stack

https://miro.com/app/board/o9J_kvfytDI=/

## Diagram

TODO

## Specifications

We target v0.12.1 phase0 of https://github.com/ethereum/eth2.0-specs
- https://github.com/ethereum/eth2.0-specs/tree/v0.12.1/specs/phase0

The p2p-interface specs in particular describe the subset of libp2p spec that
are used to implement Ethereum 2
