# Create a wallet and make a deposit

In this page we'll take you through how to create a wallet (technically a walletstore) to help generate your keystores and make a deposit using Nimbus (from now on we'll use the terms wallet and walletstore interchangeably).

> **Note:** this page is primarily aimed at users who wish to run multiple validators on several machines. If you only want to get one validator up and running with Nimbus and/or run your validators on a single machine, we recommend following [this tutorial](./medalla.md) instead.

The wallet we'll create will be [hierarchical deterministic](https://github.com/ethereum/EIPs/blob/4494da0966afa7318ec0157948821b19c4248805/EIPS/eip-2386.md).

> **Note:** for our purposes, a wallet is the [EIP-2386](https://github.com/ethereum/EIPs/blob/4494da0966afa7318ec0157948821b19c4248805/EIPS/eip-2386.md) JSON file which contains an encrypted seed, a name, and a counter (`nextaccount`) that allows for creating validators (generating keystores) incrementally as outlined in [EIP-2334](https://eips.ethereum.org/EIPS/eip-2334) (Deterministic Account Hierarchy).

An HD wallet can create keys from a *seed* and a *path*. The encrypted seed is stored in the wallet (it needs to be accessible to create new keys). Further, HD wallets also have a mechanism (a `nextaccount` index) for maintaining state about which keys have been generated (to help ensure you don't duplicate your keys by accident).

## When do I need to use a walletstore?

If you're asking yourself this question then you probably don't need to use one :)

To be clear, the purpose of a walletstore is to help you generate new keystores (and keep track of how many you've generated). But you don't need a walletstore to do this.

> Tip: You can use the Ethereum Foundation's [launchpad](https://medalla.launchpad.ethereum.org/) or [deposit-cli](https://github.com/ethereum/eth2.0-deposit-cli) to generate keystores without a walletstore.

## Prerequisites

Make sure you've gone through the [installation guidelines](./install.md) and [built the beacon node](./beacon_node.md#building-the-node).

## Create  a wallet
```
build/beacon_node wallets create
```

*TO BE FILLED*

## Create a deposit
```
build/beacon_node deposits create
```

*TO BE FILLED*

*Creates a deposits_data file that should be compatible with the new Ethereum Launchpad.*

- creates wallet
- generates deposits
- writes to deposit_data file

> Note: when you create deposits with `deposits create`, you can reference an existing wallet or you can create a new one which will guide through the standard wallets create procedure.

## Which keys do i pass to my validator client?

Importantly, to run a validator you only need to pass the voting keystore which leaks nothing about the withdrawal key (except perhaps the path that it can be derived with).

