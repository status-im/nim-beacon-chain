# TODO: How can this be tested?
proc uncompressFramedStream*(conn: Connection,
                             expectedSize: int): Future[Result[seq[byte], cstring]]
                            {.async.} =
  var header: array[STREAM_HEADER.len, byte]
  try:
    await conn.readExactly(addr header[0], header.len)
  except LPStreamEOFError, LPStreamIncompleteError:
    return err "Unexpected EOF before snappy header"

  if header != STREAM_HEADER.toOpenArrayByte(0, STREAM_HEADER.high):
    return err "Incorrect snappy header"

  var
    uncompressedData = newSeq[byte](MAX_UNCOMPRESSED_DATA_LEN)
    frameData = newSeq[byte](MAX_COMPRESSED_DATA_LEN)
    output = newSeqOfCap[byte](expectedSize)

  while output.len < expectedSize:
    var frameHeader: array[4, byte]
    try:
      await conn.readExactly(addr frameHeader[0], frameHeader.len)
    except LPStreamEOFError, LPStreamIncompleteError:
      return err "no snappy frame"

    let x = uint32.fromBytesLE frameHeader
    let id = x and 0xFF
    let dataLen = (x shr 8).int

    if dataLen > MAX_COMPRESSED_DATA_LEN:
      return err "invalid snappy frame length"

    if dataLen > 0:
      try:
        await conn.readExactly(addr frameData[0], dataLen)
      except LPStreamEOFError, LPStreamIncompleteError:
        return err "Incomplete snappy frame"

    if id == COMPRESSED_DATA_IDENTIFIER:
      if dataLen < 4:
        return err "Snappy frame size too low to contain CRC checksum"

      let
        crc = uint32.fromBytesLE frameData.toOpenArray(0, 3)
        remaining = expectedSize - output.len
        chunkLen = min(remaining, uncompressedData.len)

      # Grab up to MAX_UNCOMPRESSED_DATA_LEN bytes, but no more than remains
      # according to the expected size. If it turns out that the uncompressed
      # data is longer than that, snappyUncompress will fail and we will not
      # decompress the chunk at all, instead reporting failure.
      let
        # The `int` conversion below is safe, because `uncompressedLen` is
        # bounded to `chunkLen` (which in turn is bounded by `MAX_CHUNK_SIZE`).
        # TODO: Use a range type for the parameter.
        uncompressedLen = int snappyUncompress(
          frameData.toOpenArray(4, dataLen - 1),
          uncompressedData.toOpenArray(0, chunkLen - 1))

      if uncompressedLen == 0:
        return err "Failed to decompress snappy frame"
      doAssert output.len + uncompressedLen <= expectedSize,
        "enforced by `remains` limit above"

      if not checkCrc(uncompressedData.toOpenArray(0, uncompressedLen-1), crc):
        return err "Snappy content CRC checksum failed"

      output.add uncompressedData.toOpenArray(0, uncompressedLen-1)

    elif id == UNCOMPRESSED_DATA_IDENTIFIER:
      if dataLen < 4:
        return err "Snappy frame size too low to contain CRC checksum"

      if output.len + dataLen - 4 > expectedSize:
        return err "Too much data"

      let crc = uint32.fromBytesLE frameData.toOpenArray(0, 3)
      if not checkCrc(frameData.toOpenArray(4, dataLen - 1), crc):
        return err "Snappy content CRC checksum failed"

      output.add frameData.toOpenArray(4, dataLen-1)

    elif id < 0x80:
      # Reserved unskippable chunks (chunk types 0x02-0x7f)
      # if we encounter this type of chunk, stop decoding
      # the spec says it is an error
      return err "Invalid snappy chunk type"

    else:
      # Reserved skippable chunks (chunk types 0x80-0xfe)
      # including STREAM_HEADER (0xff) should be skipped
      continue

  return ok output

proc readChunkPayload(conn: Connection, peer: Peer,
                      MsgType: type): Future[NetRes[MsgType]] {.async.} =
  let sm = now(chronos.Moment)
  let size =
    try: await conn.readVarint()
    except LPStreamEOFError: #, LPStreamIncompleteError, InvalidVarintError
      # TODO compiler error - haha, uncaught exception
      # Error: unhandled exception: closureiters.nim(322, 17) `c[i].kind == nkType`  [AssertionError]
      return neterr UnexpectedEOF
    except LPStreamIncompleteError:
      return neterr UnexpectedEOF
    except InvalidVarintError:
      return neterr UnexpectedEOF

  if size > MAX_CHUNK_SIZE:
    return neterr SizePrefixOverflow
  if size == 0:
    return neterr ZeroSizePrefix

  # The `size.int` conversion is safe because `size` is bounded to `MAX_CHUNK_SIZE`
  let data = await conn.uncompressFramedStream(size.int)
  if data.isOk:
    # `10` is the maximum size of variable integer on wire, so error could
    # not be significant.
    peer.updateNetThroughput(now(chronos.Moment) - sm,
                              uint64(10 + size))
    return ok SSZ.decode(data.get(), MsgType)
  else:
    debug "Snappy decompression/read failed", msg = $data.error, conn
    return neterr InvalidSnappyBytes

proc readResponseChunk(conn: Connection, peer: Peer,
                       MsgType: typedesc): Future[NetRes[MsgType]] {.async.} =
  try:
    var responseCodeByte: byte
    try:
      await conn.readExactly(addr responseCodeByte, 1)
    except LPStreamEOFError, LPStreamIncompleteError:
      return neterr PotentiallyExpectedEOF

    static: assert ResponseCode.low.ord == 0
    if responseCodeByte > ResponseCode.high.byte:
      return neterr InvalidResponseCode

    let responseCode = ResponseCode responseCodeByte
    case responseCode:
    of InvalidRequest, ServerError:
      let errorMsgChunk = await readChunkPayload(conn, peer, ErrorMsg)
      let errorMsg = if errorMsgChunk.isOk: errorMsgChunk.value
                     else: return err(errorMsgChunk.error)
      return err Eth2NetworkingError(kind: ReceivedErrorResponse,
                                     responseCode: responseCode,
                                     errorMsg: errorMsg)
    of Success:
      discard

    return await readChunkPayload(conn, peer, MsgType)

  except LPStreamEOFError, LPStreamIncompleteError:
    return neterr UnexpectedEOF

proc readResponse(conn: Connection, peer: Peer,
                  MsgType: type, timeout: Option[Duration]): Future[NetRes[MsgType]] {.async.} =
  when MsgType is seq:
    type E = ElemType(MsgType)
    var results: MsgType
    while true:
      # Because we interleave networking with response processing, it may
      # happen that reading all chunks takes longer than a strict dealine
      # timeout would allow, so we allow each chunk a new timeout instead.
      # The problem is exacerbated by the large number of round-trips to the
      # poll loop that each future along the way causes.
      trace "reading chunk", conn
      let nextFut = conn.readResponseChunk(peer, E)
      let nextRes = if timeout.isSome():
          if not await nextFut.withTimeout(timeout.get()):
            return neterr(ReadResponseTimeout)
          nextFut.read()
        else:
          await nextFut
      if nextRes.isErr:
        if nextRes.error.kind == PotentiallyExpectedEOF:
          trace "EOF chunk", conn, err = nextRes.error

          return ok results
        trace "Error chunk", conn, err = nextRes.error

        return err nextRes.error
      else:
        trace "Got chunk", conn
        results.add nextRes.value
  else:
    let nextFut = conn.readResponseChunk(peer, MsgType)
    if timeout.isSome():
      if not await nextFut.withTimeout(timeout.get()):
        return neterr(ReadResponseTimeout)
      return nextFut.read()
    else:
      return await nextFut

