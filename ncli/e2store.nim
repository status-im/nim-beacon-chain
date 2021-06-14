{.push raises: [Defect].}

import
  stew/[endians2, results], ssz_serialization/ssz,
  snappy, snappy/framing,
  ../beacon_chain/spec/datatypes

const
  E2Version = [byte 0x65, 0x32]
  E2Index = [byte 0x69, 0x32]
  SnappyBeaconBlock = [byte 0x01, 0x00]
  SnappyBeaconState = [byte 0x02, 0x00]

type
  E2Store* = object
    data: File
    index: File
    slot: Slot

  Header* = object
    typ*: array[2, byte]
    len*: uint64

proc append(f: File, data: openArray[byte]): Result[void, string] =
  try:
    if writeBytes(f, data, 0, data.len()) != data.len:
      err("Cannot write to file")
    else:
      ok()
  except CatchableError as exc:
    err(exc.msg)

proc readHeader(f: File): Result[Header, string] =
  try:
    var buf: array[8, byte]
    if system.readBuffer(f, addr buf[0], 8)  != 8:
      return err("Not enough bytes for header")
  except CatchableError as e:
    return err("Cannot read header")

proc appendRecord(f: File, typ: array[2, byte], data: openArray[byte]): Result[int64, string] =
  try:
    let start = getFilePos(f)
    let dlen = toBytesLE(data.len().uint64)

    ? append(f, typ)
    ? append(f, dlen.toOpenArray(0, 5))
    ? append(f, data)
    ok(start)
  except CatchableError as e:
    err(e.msg)

proc open*(T: type E2Store, path: string, name: string, firstSlot: Slot): Result[E2Store, string] =
  let
    data =
      try: open(path / name & ".e2s", fmWrite)
      except CatchableError as e: return err(e.msg)
    index =
      try: system.open(path / name & ".e2i", fmWrite)
      except CatchableError as e:
        close(data)
        return err(e.msg)
  discard ? appendRecord(data, E2Version, [])
  discard ? appendRecord(index, E2Index, [])
  ? append(index, toBytesLE(firstSlot.uint64))

  ok(E2Store(data: data, index: index, slot: firstSlot))

proc close*(store: var E2Store) =
  store.data.close()
  store.index.close()

proc toCompressedBytes(item: auto): seq[byte] =
  try:
    let
      payload = SSZ.encode(item)
    framingFormatCompress(payload)
  except CatchableError as exc:
    raiseAssert exc.msg # shouldn't happen

proc appendRecord*(store: var E2Store, v: SomeSignedBeaconBlock): Result[void, string] =
  if v.message.slot < store.slot:
    return err("Blocks must be written in order")
  let start = store.data.appendRecord(SnappyBeaconBlock, toCompressedBytes(v)).get()
  while store.slot < v.message.slot:
    ? append(store.index, toBytesLE(0'u64))
    store.slot += 1
  ? append(store.index, toBytesLE(start.uint64))
  store.slot += 1

  ok()

proc appendRecord*(store: var E2Store, v: BeaconState): Result[void, string] =
  discard ? store.data.appendRecord(SnappyBeaconState, toCompressedBytes(v))
  ok()
