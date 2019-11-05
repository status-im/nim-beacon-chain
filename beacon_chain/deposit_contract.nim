import
  os, strutils, options, json,
  chronos, nimcrypto, confutils, web3, stint,
  eth/keys

# Compiled version of /scripts/depositContract.v.py in this repo
# The contract was compiled in Remix (https://remix.ethereum.org/) with vyper (remote) compiler.
const contractCode = "0x740100000000000000000000000000000000000000006020526f7fffffffffffffffffffffffffffffff6040527fffffffffffffffffffffffffffffffff8000000000000000000000000000000060605274012a05f1fffffffffffffffffffffffffdabf41c006080527ffffffffffffffffffffffffed5fa0e000000000000000000000000000000000060a052341561009857600080fd5b336003556101406000601f818352015b600061014051602081106100bb57600080fd5b600260c052602060c020015460208261016001015260208101905061014051602081106100e757600080fd5b600260c052602060c020015460208261016001015260208101905080610160526101609050602060c0825160208401600060025af161012557600080fd5b60c0519050606051600161014051018060405190131561014457600080fd5b809190121561015257600080fd5b6020811061015f57600080fd5b600260c052602060c02001555b81516001018083528114156100a8575b505061129656600035601c52740100000000000000000000000000000000000000006020526f7fffffffffffffffffffffffffffffff6040527fffffffffffffffffffffffffffffffff8000000000000000000000000000000060605274012a05f1fffffffffffffffffffffffffdabf41c006080527ffffffffffffffffffffffffed5fa0e000000000000000000000000000000000060a052600015610277575b6101605261014052600061018052610140516101a0526101c060006008818352015b61018051600860008112156100da578060000360020a82046100e1565b8060020a82025b905090506101805260ff6101a051166101e052610180516101e0516101805101101561010c57600080fd5b6101e0516101805101610180526101a0517ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff86000811215610155578060000360020a820461015c565b8060020a82025b905090506101a0525b81516001018083528114156100bd575b50506018600860208206610200016020828401111561019357600080fd5b60208061022082610180600060046015f15050818152809050905090508051602001806102c0828460006004600a8704601201f16101d057600080fd5b50506102c05160206001820306601f82010390506103206102c0516008818352015b826103205111156102025761021e565b6000610320516102e001535b81516001018083528114156101f2575b50505060206102a05260406102c0510160206001820306601f8201039050610280525b6000610280511115156102535761026f565b602061028051036102a001516020610280510361028052610241565b610160515650005b63c5f2892f600051141561050957341561029057600080fd5b6000610140526101405161016052600154610180526101a060006020818352015b60016001610180511614156103325760006101a051602081106102d357600080fd5b600060c052602060c02001546020826102400101526020810190506101605160208261024001015260208101905080610240526102409050602060c0825160208401600060025af161032457600080fd5b60c0519050610160526103a0565b6000610160516020826101c00101526020810190506101a0516020811061035857600080fd5b600260c052602060c02001546020826101c0010152602081019050806101c0526101c09050602060c0825160208401600060025af161039657600080fd5b60c0519050610160525b61018060026103ae57600080fd5b60028151048152505b81516001018083528114156102b1575b505060006101605160208261046001015260208101905061014051610160516101805163806732896102e05260015461030052610300516006580161009b565b506103605260006103c0525b6103605160206001820306601f82010390506103c0511015156104355761044e565b6103c05161038001526103c0516020016103c052610413565b61018052610160526101405261036060088060208461046001018260208501600060046012f150508051820191505060006018602082066103e0016020828401111561049957600080fd5b60208061040082610140600060046015f150508181528090509050905060188060208461046001018260208501600060046014f150508051820191505080610460526104609050602060c0825160208401600060025af16104f957600080fd5b60c051905060005260206000f350005b63621fd130600051141561061c57341561052257600080fd5b63806732896101405260015461016052610160516006580161009b565b506101c0526000610220525b6101c05160206001820306601f82010390506102205110151561056d57610586565b610220516101e00152610220516020016102205261054b565b6101c0805160200180610280828460006004600a8704601201f16105a957600080fd5b50506102805160206001820306601f82010390506102e0610280516008818352015b826102e05111156105db576105f7565b60006102e0516102a001535b81516001018083528114156105cb575b5050506020610260526040610280510160206001820306601f8201039050610260f350005b632289511860005114156110d957605060043560040161014037603060043560040135111561064a57600080fd5b60406024356004016101c037602060243560040135111561066a57600080fd5b608060443560040161022037606060443560040135111561068a57600080fd5b63ffffffff6001541061069c57600080fd5b633b9aca006102e0526102e0516106b257600080fd5b6102e05134046102c052633b9aca006102c05110156106d057600080fd5b603061014051146106e057600080fd5b60206101c051146106f057600080fd5b6060610220511461070057600080fd5b610140610360525b6103605151602061036051016103605261036061036051101561072a57610708565b6380673289610380526102c0516103a0526103a0516006580161009b565b50610400526000610460525b6104005160206001820306601f8201039050610460511015156107765761078f565b6104605161042001526104605160200161046052610754565b610340610360525b61036051526020610360510361036052610140610360511015156107ba57610797565b610400805160200180610300828460006004600a8704601201f16107dd57600080fd5b5050610140610480525b61048051516020610480510161048052610480610480511015610809576107e7565b63806732896104a0526001546104c0526104c0516006580161009b565b50610520526000610580525b6105205160206001820306601f8201039050610580511015156108545761086d565b6105805161054001526105805160200161058052610832565b610460610480525b610480515260206104805103610480526101406104805110151561089857610875565b6105208051602001806105a0828460006004600a8704601201f16108bb57600080fd5b505060a06106205261062051610660526101408051602001806106205161066001828460006004600a8704601201f16108f357600080fd5b505061062051610660015160206001820306601f8201039050610620516106600161060081516040818352015b83610600511015156109315761094e565b6000610600516020850101535b8151600101808352811415610920575b50505050602061062051610660015160206001820306601f82010390506106205101016106205261062051610680526101c08051602001806106205161066001828460006004600a8704601201f16109a557600080fd5b505061062051610660015160206001820306601f8201039050610620516106600161060081516020818352015b83610600511015156109e357610a00565b6000610600516020850101535b81516001018083528114156109d2575b50505050602061062051610660015160206001820306601f820103905061062051010161062052610620516106a0526103008051602001806106205161066001828460006004600a8704601201f1610a5757600080fd5b505061062051610660015160206001820306601f8201039050610620516106600161060081516020818352015b8361060051101515610a9557610ab2565b6000610600516020850101535b8151600101808352811415610a84575b50505050602061062051610660015160206001820306601f820103905061062051010161062052610620516106c0526102208051602001806106205161066001828460006004600a8704601201f1610b0957600080fd5b505061062051610660015160206001820306601f8201039050610620516106600161060081516060818352015b8361060051101515610b4757610b64565b6000610600516020850101535b8151600101808352811415610b36575b50505050602061062051610660015160206001820306601f820103905061062051010161062052610620516106e0526105a08051602001806106205161066001828460006004600a8704601201f1610bbb57600080fd5b505061062051610660015160206001820306601f8201039050610620516106600161060081516020818352015b8361060051101515610bf957610c16565b6000610600516020850101535b8151600101808352811415610be8575b50505050602061062051610660015160206001820306601f8201039050610620510101610620527f649bbc62d0e31342afea4e5cd82d4049e7e1ee912fc0889aa790803be39038c561062051610660a160006107005260006101406030806020846107c001018260208501600060046016f150508051820191505060006010602082066107400160208284011115610cad57600080fd5b60208061076082610700600060046015f15050818152809050905090506010806020846107c001018260208501600060046013f1505080518201915050806107c0526107c09050602060c0825160208401600060025af1610d0d57600080fd5b60c0519050610720526000600060406020820661086001610220518284011115610d3657600080fd5b606080610880826020602088068803016102200160006004601bf1505081815280905090509050602060c0825160208401600060025af1610d7657600080fd5b60c0519050602082610a600101526020810190506000604060206020820661092001610220518284011115610daa57600080fd5b606080610940826020602088068803016102200160006004601bf15050818152809050905090506020806020846109e001018260208501600060046015f1505080518201915050610700516020826109e0010152602081019050806109e0526109e09050602060c0825160208401600060025af1610e2757600080fd5b60c0519050602082610a6001015260208101905080610a6052610a609050602060c0825160208401600060025af1610e5e57600080fd5b60c0519050610840526000600061072051602082610b000101526020810190506101c0602080602084610b0001018260208501600060046015f150508051820191505080610b0052610b009050602060c0825160208401600060025af1610ec457600080fd5b60c0519050602082610c800101526020810190506000610300600880602084610c0001018260208501600060046012f15050805182019150506000601860208206610b800160208284011115610f1957600080fd5b602080610ba082610700600060046015f1505081815280905090509050601880602084610c0001018260208501600060046014f150508051820191505061084051602082610c0001015260208101905080610c0052610c009050602060c0825160208401600060025af1610f8c57600080fd5b60c0519050602082610c8001015260208101905080610c8052610c809050602060c0825160208401600060025af1610fc357600080fd5b60c0519050610ae052606435610ae05114610fdd57600080fd5b6001805460018254011015610ff157600080fd5b6001815401815550600154610d0052610d2060006020818352015b60016001610d005116141561104157610ae051610d20516020811061103057600080fd5b600060c052602060c02001556110d5565b6000610d20516020811061105457600080fd5b600060c052602060c0200154602082610d40010152602081019050610ae051602082610d4001015260208101905080610d4052610d409050602060c0825160208401600060025af16110a557600080fd5b60c0519050610ae052610d0060026110bc57600080fd5b60028151048152505b815160010180835281141561100c575b5050005b639890220b600051141561110d5734156110f257600080fd5b600060006000600030316003546000f161110b57600080fd5b005b60006000fd5b61018361129603610183600039610183611296036000f3"

type
  StartUpCommand {.pure.} = enum
    deploy
    drain
    sendEth

  CliConfig = object
    depositWeb3Url* {.
      desc: "URL of the Web3 server to observe Eth1"
      longform: "web3-url" }: string

    privateKey* {.
      desc: "Private key of the controlling account",
      defaultValue: ""
      longform: "private-key" }: string

    case cmd* {.command.}: StartUpCommand
    of deploy:
      discard

    of drain:
      contractAddress* {.
        desc: "Address of the contract to drain",
        defaultValue: ""
        longform: "deposit-contract" }: string

    of sendEth:
      toAddress {.longform: "to".}: string
      valueEth {.longform: "eth".}: string

contract(Deposit):
  proc drain()

proc deployContract*(web3: Web3, code: string): Future[Address] {.async.} =
  var code = code
  if code[1] notin {'x', 'X'}:
    code = "0x" & code
  let tr = EthSend(
    source: web3.defaultAccount,
    data: code,
    gas: Quantity(3000000).some,
    gasPrice: 1.some)

  let r = await web3.send(tr)
  let receipt = await web3.getMinedTransactionReceipt(r)
  result = receipt.contractAddress.get

proc sendEth(web3: Web3, to: string, valueEth: int): Future[TxHash] =
  let tr = EthSend(
    source: web3.defaultAccount,
    gas: Quantity(3000000).some,
    gasPrice: 1.some,
    value: some(valueEth.u256 * 1000000000000000000.u256),
    to: Address.fromHex(to).some)
  web3.send(tr)

proc main() {.async.} =
  let cfg = CliConfig.load()
  let web3 = await newWeb3(cfg.depositWeb3Url)
  if cfg.privateKey.len != 0:
    web3.privateKey = initPrivateKey(cfg.privateKey)
  else:
    let accounts = await web3.provider.eth_accounts()
    assert(accounts.len > 0)
    web3.defaultAccount = accounts[0]

  case cfg.cmd
  of StartUpCommand.deploy:
    let contractAddress = await web3.deployContract(contractCode)
    echo "0x", contractAddress
  of StartUpCommand.drain:
    let sender = web3.contractSender(Deposit, Address.fromHex(cfg.contractAddress))
    discard await sender.drain().send(gasPrice = 1)

  of StartUpCommand.sendEth:
    echo "0x", await sendEth(web3, cfg.toAddress, cfg.valueEth.parseInt)

when isMainModule: waitFor main()
