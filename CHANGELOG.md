2020-11-20 v1.0.0-rc1
=====================

We're happy to join the other client teams in announcing our `v1.0.0` release
candidate with support for Mainnet ✨

You can use this release/binary to set up your rig and monitoring for Eth2
genesis next Tuesday (*December 1 12:00:23 UTC*).

> **N.B.** There will be at least one more release, before December 1st.
> In particular, **we are planning a more polished release for Sunday** which
> will act as a drop-in replacement for this release candidate.

Don't worry if your peer count appears low at first -- It should increase as
more validators connect to Mainnet.

-----------------

**Highlights include:**

* The addition of a deposit contract "state snapshot"  to network metadata.
  This allows the client to skip syncing deposits made prior to the snapshot.

* A much faster startup time. We've removed the deposits table from the database,
  which means the client no longer needs to process all deposits on start-up.

* The Eth1 monitor no longer starts if the beacon node has zero validators attached to it.

* The genesis detection code is now optional and disabled by default.

* An RPC call to get Chronos futures at runtime.

* Eth2 spec gossip parameters.

**We've fixed:**

* A database corruption issue affecting Pyrmont nodes.

* Unnecessary copy/memory alloc when loading DbSeq entries.

* A block production issue affecting clients that hadn't finished downloading the latest deposits. 


2020-11-20 v0.6.6
=================

New additions:

* New RPC APIs for inspecting the internal state of the Eth1 monitor.

We've fixed:

* A fork-choice issue causing Nimbus to get stuck on a particular slot.

* A logic error causing Nimbus to vote for an incorrect Eth1 block.

* A crash during initialization when the web3 provider is refusing
  to serve data (e.g. due to exceeded request quota).


2020-11-17 v0.6.4
=================

New additions:

* Support for the Pyrmont testnet.

* The PCRE library is no longer necessary for building Nimbus.

* Sensitive files such as keystores are now accessible only to the
  user of the beacon node on POSIX systems (the group rights have
  been dropped).

We've fixed:

* An issue preventing blocks to be downloaded when the client goes
  out of sync.

* Resource leaks that may lead to reduction of network activity due
  to a build-up of malfunctioning peer connections.


2020-11-12 v0.6.2
=================

A bugfix release addressing issues discovered in the Toledo network.

New features include:

* GossipSub 1.1

* The beacon node status bar (footer) now contains a
  time-left-until-synced estimate.

* A JSON-RPC method `setLogLevel` for dynamically changing the
  log level of selected components at run-time.

* The ability to launch Nimbus with a partially-synced Geth node.

We've fixed:

* A bug preventing the node from proposing blocks when connected
  to a web3 provider

* An invalid "corrupted database" error message appearing on start-up

* Incorrectly set message-ids in gossip message causing other clients
  to penalise and potentially disconnect our nodes from the network.

* An issue occuring when Nimbus is paired with a Geth node
  that is not fully synced.


2020-11-09 Hope (v0.6.0)
========================

`Nimbus eth2` 0.6.0 was the first externally audited and stable release
of our beacon node software. When compared to the 0.5x series, it features
significant reductions in storage and memory requirements, a faster sync
speed, and a plethora of usability and security enhancements across the
board. Under normal network conditions, the delivery rate of attestations
and block proposals is expected to be above 99%. Going forward, our release
schedule will start to accelerate, with multiple new releases expected before
the Eth2 mainnet launch.

Changelog highlights include:

* Full support for the 1.0 Eth2 phase0 spec and the monitoring of the
  mainnet validator deposit contract.

* LibP2P and GossipSub fixes which drastically improve the delivery of
  attestations and blocks (nearly 100% expected rate of delivery).

* Fixes for all major resource leaks: you no longer need to restart your
  node to improve its performance.

* Efficient caching and storage mechanisms: ensures our memory consumption
  remains comparatively low both during smooth and turbulent network conditions.

* Several storage and networking optimisations leading to an order of magnitude
  improvement in beacon chain sync speed.

* Audits to our codebase by ConsenSys Diligence, NCC Group and Trail of Bits.
  More than 60 of the security findings have already been addressed.
  The remaining items will be resolved before mainnet launch.

* Support for pairing with a locally running Geth instance to allow for
  decentralised monitoring of the validator deposit contract.

* An extensive user guide for managing the beacon node.

* Slashing protection mechanisms + database.

* Support for storing the validator signing keys in a separate process, isolated
  from the network, with a minimal attack surface.

