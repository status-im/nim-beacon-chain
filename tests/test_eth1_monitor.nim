{.used.}

import
  unittest2,
  chronos, web3/ethtypes,
  ../beacon_chain/eth1/eth1_monitor,
  ./testutil

suite "Eth1 Chain":
  discard

suite "Eth1 monitor":
  test "Rewrite HTTPS Infura URLs":
    var
      mainnetWssUrl = "wss://mainnet.infura.io/ws/v3/6224f3c792cc443fafb64e70a98f871e"
      mainnetHttpUrl = "http://mainnet.infura.io/v3/6224f3c792cc443fafb64e70a98f871e"
      mainnetHttpsUrl = "https://mainnet.infura.io/v3/6224f3c792cc443fafb64e70a98f871e"
      goerliWssUrl = "wss://goerli.infura.io/ws/v3/6224f3c792cc443fafb64e70a98f871e"
      goerliHttpUrl = "http://goerli.infura.io/v3/6224f3c792cc443fafb64e70a98f871e"
      goerliHttpsUrl = "https://goerli.infura.io/v3/6224f3c792cc443fafb64e70a98f871e"
      gethHttpUrl = "http://localhost:8545"
      gethHttpsUrl = "https://localhost:8545"
      gethWsUrl = "ws://localhost:8545"
      unspecifiedProtocolUrl = "localhost:8545"

    fixupWeb3Urls mainnetWssUrl
    fixupWeb3Urls mainnetHttpUrl
    fixupWeb3Urls mainnetHttpsUrl
    fixupWeb3Urls goerliWssUrl
    fixupWeb3Urls goerliHttpUrl
    fixupWeb3Urls goerliHttpsUrl
    fixupWeb3Urls gethHttpUrl
    fixupWeb3Urls gethHttpsUrl
    fixupWeb3Urls gethWsUrl
    fixupWeb3Urls unspecifiedProtocolUrl

    check:
      mainnetWssUrl == "wss://mainnet.infura.io/ws/v3/6224f3c792cc443fafb64e70a98f871e"
      mainnetHttpUrl == "http://mainnet.infura.io/v3/6224f3c792cc443fafb64e70a98f871e"
      mainnetHttpsUrl == "https://mainnet.infura.io/v3/6224f3c792cc443fafb64e70a98f871e"

      goerliWssUrl == "wss://goerli.infura.io/ws/v3/6224f3c792cc443fafb64e70a98f871e"
      goerliHttpUrl == "http://goerli.infura.io/v3/6224f3c792cc443fafb64e70a98f871e"
      goerliHttpsUrl == "https://goerli.infura.io/v3/6224f3c792cc443fafb64e70a98f871e"

      gethHttpUrl == "http://localhost:8545"
      gethHttpsUrl == "https://localhost:8545"
      unspecifiedProtocolUrl == "ws://localhost:8545"

      gethWsUrl == "ws://localhost:8545"
