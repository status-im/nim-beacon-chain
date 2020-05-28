import
  confutils, os, strutils, chronicles, json_serialization,
  stew/byteutils,
  ../beacon_chain/spec/[crypto, datatypes, digest],
  ../beacon_chain/[ssz],
  ../beacon_chain/ssz/dynamic_navigator

type
  QueryCmd* = enum
    nimQuery
    get

  QueryConf = object
    file* {.
        defaultValue: ""
        desc: "BeaconState ssz file"
        name: "file" }: InputFile

    case queryCmd* {.
      defaultValue: nimQuery
      command
      desc: "Query the beacon node database and print the result" }: QueryCmd

    of nimQuery:
      nimQueryExpression* {.
        argument
        desc: "Nim expression to evaluate (using limited syntax)" }: string

    of get:
      getQueryPath* {.
        argument
        desc: "REST API path to evaluate" }: string


let
  config = QueryConf.load()

case config.queryCmd
of QueryCmd.nimQuery:
  # TODO: This will handle a simple subset of Nim using
  #       dot syntax and `[]` indexing.
  echo "nim query: ", config.nimQueryExpression

of QueryCmd.get:
  let pathFragments = config.getQueryPath.split('/', maxsplit = 1)
  let bytes =
    case pathFragments[0]
    of "genesis_state":
      readFile(config.file.string).string.toBytes()
    else:
      stderr.write config.getQueryPath & " is not a valid path"
      quit 1

  let navigator = DynamicSszNavigator.init(bytes, BeaconState)

  echo navigator.navigatePath(pathFragments[1 .. ^1]).toJson
