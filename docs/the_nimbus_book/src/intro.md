# The Nimbus book

Nimbus is a client implementation for both Ethereum 2.0 and Ethereum 1.0 that strives to be as lightweight as possible in terms of resources used. This allows it to perform well on embedded systems, resource-restricted devices -- including Raspberry Pis and mobile devices.

> If you're eager to get started, check out our [quickstart guide](./quick-start.md).

However, resource-restricted hardware is not the only thing Nimbus is good for. Its low resource consumption makes it easy to run Nimbus together with other workloads on your server (this is especially valuable for stakers looking to lower the cost of their server instances).

This book explains the ways in which you can use Nimbus to either monitor the eth2 chain or become a fully-fledged validator.

> **N.B.** The reality is that we are very early in the eth2 validating life cycle. Validating is not for everyone yet, and it comes with both risks and responsibilities. It isn't a particularly easy way to make money. You'll need to put effort into updating your software, researching hard-forks, having a robust setup... . As such, you should only stake if you are genuinely interested in securing the protocol.



### Helpful resources

- [nimbus-eth2 repository](https://github.com/status-im/nimbus-eth2)
- [eth2 specification](https://github.com/ethereum/eth2.0-specs/tree/v1.0.0#phase-0)
- [Ben Edgington's annotated spec](https://benjaminion.xyz/eth2-annotated-spec/phase0/beacon-chain/) 

- [Vitalik's annotated spec](https://github.com/ethereum/annotated-spec/blob/master/phase0/beacon-chain.md)

- [Danny Ryan's annotated spec](https://notes.ethereum.org/@djrtwo/Bkn3zpwxB)


### Why eth2?

Eth2 is a multi-year plan to improve the scalability, security, and programmability of Ethereum, without compromising on decentralisation.

In contrast to the Ethereum chain, as it currently stands, eth2 uses proof-of-stake (PoS) to secure its network. And while Ethereum as you know and love it will continue to exist as its own independent proof-of-work chain for a little while to come, the transition towards PoS starts now.

> In traditional PoW, block proposers are called **_miners_**, whereas in PoS, they are called **_validators_**. In essence, _miners_ rely on actual hardware (such as some specifically manufactured mining machines), while _validators_ rely on software (such as Nimbus) and a good network connection.


### Get in touch

Need help with anything? Join us on [Status](https://join.status.im/nimbus-general) and [Discord](https://discord.gg/9dWwPnG).


### Disclaimer

This documentation assumes Nimbus is in its ideal state. The project is still under active development. Please submit a [Github issue](https://github.com/status-im/nimbus-eth2/issues) if you come across a problem.

<!-- > > > TODO:

1. fill up the gitbook content
2. write questions in the faq.md page -->
