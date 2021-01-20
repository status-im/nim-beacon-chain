import
  std/[os, strutils, terminal, wordwrap, unicode],
  chronicles, chronos, web3, stint, json_serialization, zxcvbn,
  serialization, blscurve, eth/common/eth_types, eth/keys, confutils, bearssl,
  spec/[datatypes, digest, crypto, keystore],
  stew/io2, libp2p/crypto/crypto as lcrypto,
  nimcrypto/utils as ncrutils,
  conf, ssz/merkleization, network_metadata, filepath

export
  keystore

when defined(windows):
  import stew/[windows/acl]

{.push raises: [Defect].}
{.localPassC: "-fno-lto".} # no LTO for crypto

const
  keystoreFileName* = "keystore.json"
  netKeystoreFileName* = "network_keystore.json"

type
  WalletPathPair* = object
    wallet*: Wallet
    path*: string

  CreatedWallet* = object
    walletPath*: WalletPathPair
    seed*: KeySeed

  KeystoreFlags* = enum
    NonInteractive, InsecurePassword

  Configurations* = BeaconNodeConf | ValidatorClientConf

const
  minPasswordLen = 12
  minPasswordEntropy = 60.0

  mostCommonPasswords = wordListArray(
    currentSourcePath.parentDir /
      "../vendor/nimbus-security-resources/passwords/10-million-password-list-top-100000.txt",
    minWordLen = minPasswordLen)

proc echoP*(msg: string) =
  ## Prints a paragraph aligned to 80 columns
  echo ""
  echo wrapWords(msg, 80)

proc checkAndCreateDataDir*(dataDir: string): bool =
  when defined(posix):
    let requiredPerms = 0o700
    if isDir(dataDir):
      let currPermsRes = getPermissions(dataDir)
      if currPermsRes.isErr():
        fatal "Could not check data directory permissions",
               data_dir = dataDir, errorCode = $currPermsRes.error,
               errorMsg = ioErrorMsg(currPermsRes.error)
        return false
      else:
        let currPerms = currPermsRes.get()
        if currPerms != requiredPerms:
          warn "Data directory has insecure permissions. Correcting them.",
                data_dir = dataDir,
                current_permissions = currPerms.toOct(4),
                required_permissions = requiredPerms.toOct(4)
          let newPermsRes = setPermissions(dataDir, requiredPerms)
          if newPermsRes.isErr():
            fatal "Could not set data directory permissions",
                   data_dir = dataDir,
                   errorCode = $newPermsRes.error,
                   errorMsg = ioErrorMsg(newPermsRes.error),
                   old_permissions = currPerms.toOct(4),
                   new_permissions = requiredPerms.toOct(4)
            return false
    else:
      let res = secureCreatePath(dataDir)
      if res.isErr():
        fatal "Could not create data directory", data_dir = dataDir,
              errorMsg = ioErrorMsg(res.error), errorCode = $res.error
        return false
  elif defined(windows):
    let amask = {AccessFlags.Read, AccessFlags.Write, AccessFlags.Execute}
    if fileAccessible(dataDir, amask):
      let cres = checkCurrentUserOnlyACL(dataDir)
      if cres.isErr():
        fatal "Could not check data folder's ACL",
               data_dir = dataDir, errorCode = $cres.error,
               errorMsg = ioErrorMsg(cres.error)
        return false
      else:
        if cres.get() == false:
          fatal "Data folder has insecure ACL", data_dir = dataDir
          return false
    else:
      let res = secureCreatePath(dataDir)
      if res.isErr():
        fatal "Could not create data folder", data_dir = dataDir,
                errorMsg = ioErrorMsg(res.error), errorCode = $res.error
        return false
  else:
    fatal "Unsupported operation system"
    return false

  return true

proc checkSensitiveFilePermissions*(filePath: string): bool =
  ## Check if ``filePath`` has only "(600) rw-------" permissions.
  ## Procedure returns ``false`` if permissions are different and we can't
  ## correct them.
  when defined(windows):
    let cres = checkCurrentUserOnlyACL(filePath)
    if cres.isErr():
      fatal "Could not check file's ACL",
             key_path = filePath, errorCode = $cres.error,
             errorMsg = ioErrorMsg(cres.error)
      return false
    else:
      if cres.get() == false:
        fatal "File has insecure permissions", key_path = filePath
        return false
  else:
    let requiredPerms = 0o600
    let currPermsRes = getPermissions(filePath)
    if currPermsRes.isErr():
      error "Could not check file permissions",
            key_path = filePath, errorCode = $currPermsRes.error,
            errorMsg = ioErrorMsg(currPermsRes.error)
      return false
    else:
      let currPerms = currPermsRes.get()
      if currPerms != requiredPerms:
        warn "File has insecure permissions. Correcting them.",
              key_path = filePath,
              current_permissions = currPerms.toOct(4),
              required_permissions = requiredPerms.toOct(4)
        let newPermsRes = setPermissions(filePath, requiredPerms)
        if newPermsRes.isErr():
          fatal "Could not set data directory permissions",
                 key_path = filePath,
                 errorCode = $newPermsRes.error,
                 errorMsg = ioErrorMsg(newPermsRes.error),
                 old_permissions = currPerms.toOct(4),
                 new_permissions = requiredPerms.toOct(4)
          return false

  return true

proc getNetKeystoreFlags*(conf: BeaconNodeConf): set[KeystoreFlags] =
  ## Calculate network KeystoreFlags according to configuration arguments.
  var res: set[KeystoreFlags]
  if conf.nonInteractive:
    res.incl(KeystoreFlags.NonInteractive)
  if conf.netKeyInsecurePassword:
    res.incl(KeystoreFlags.InsecurePassword)
  res

proc getKeystoreFlags*(conf: Configurations): set[KeystoreFlags] =
  ## Calculate valudator's KeystoreFlags according to configuration arguments.
  when conf is BeaconNodeConf:
    var res: set[KeystoreFlags]
    if conf.nonInteractive:
      res.incl(KeystoreFlags.NonInteractive)
    if conf.keyInsecurePassword:
      res.incl(KeystoreFlags.InsecurePassword)
    res
  else:
    var res: set[KeystoreFlags]
    if conf.nonInteractive:
      res.incl(KeystoreFlags.NonInteractive)
    res

proc keyboardCreatePassword(prompt: string,
                            confirm: string,
                            allowEmpty = false): KsResult[string] =
  while true:
    let password =
      try:
        readPasswordFromStdin(prompt)
      except IOError:
        error "Could not read password from stdin"
        return err("Could not read password from stdin")

    if password.len == 0 and allowEmpty:
      echoP "WARNING! You entered an empty password, which is not SECURE. " &
            "Please confirm your decision by entering word \"empty\"."

      let confirmEmpty =
        try:
          readPasswordFromStdin(confirm)
        except IOError:
          error "Could not read password from stdin"
          return err("Could not read password from stdin")

      if confirmEmpty != "empty":
        echo "An empty password was not confirmed!"
        continue

      return ok("")

    # We treat `password` as UTF-8 encoded string.
    if validateUtf8(password) == -1:
      if runeLen(password) < minPasswordLen:
        echoP "The entered password should be at least " & $minPasswordLen &
              " characters."
        echo ""
        continue
      elif passwordEntropy(password) < minPasswordEntropy:
        echoP "The entered password has low entropy and may be easy to " &
              "brute-force with automated tools. Please increase the " &
              "variety of the user characters."
        continue
      elif password in mostCommonPasswords:
        echoP "The entered password is too commonly used and it would be " &
              "easy to brute-force with automated tools."
        echo ""
        continue
    else:
      echoP "Entered password is not valid UTF-8 string"
      echo ""
      continue

    let confirmedPassword =
      try:
        readPasswordFromStdin(confirm)
      except IOError:
        error "Could not read password from stdin"
        return err("Could not read password from stdin")

    if password != confirmedPassword:
      echo "Passwords don't match, please try again\n"
      continue

    return ok(password)

proc keyboardGetPassword[T](prompt: string, attempts: int,
                            pred: proc(p: string): KsResult[T] {.closure.}): KsResult[T] =
  var
    remainingAttempts = attempts
    counter = 1

  while remainingAttempts > 0:
    let passphrase =
      try:
        readPasswordFromStdin(prompt)
      except IOError:
        error "Could not read password from stdin"
        return
    os.sleep(1000 * counter)
    let res = pred(passphrase)
    if res.isOk():
      return res
    else:
      inc(counter)
      dec(remainingAttempts)
  err("Failed to decrypt keystore")

proc loadStore[T: Keystore|NetKeystore|Wallet](kt: typedesc[T],
                                          filename: string): Result[T, string] =
  let res = readAllChars(filename)
  if res.isOk():
    try:
      let keystore = Json.decode(res.get(), T)
      return ok(keystore)
    except SerializationError as err:
      when (T is Keystore) or (T is NetKeystore):
        error "Invalid keystore format", key_path = filename
        return err("Invalid keystore format")
      else:
        error "Invalid wallet format", wallet_path = filename
        return err("Invalid wallet format")
  else:
    when (T is Keystore) or (T is NetKeystore):
      error "Could not read keystore file", key_path = filename
      return err("Could not read keystore file")
    else:
      error "Could not read wallet file", wallet_path = filename
      return err("Could not read wallet file")

proc loadKeystore*(validatorsDir, secretsDir, keyName: string,
                   keystoreFlags: set[KeystoreFlags]): Option[ValidatorPrivKey] =
  let
    keystorePath = validatorsDir / keyName / keystoreFileName
    keystore =
      block:
        let res = Keystore.loadStore(keystorePath)
        if res.isOk():
          res.get()
        else:
          return

  let passphrasePath = secretsDir / keyName
  if fileExists(passphrasePath):
    notice "Trying to unlock keystore using password file",
           key_path = keystorePath, password_path = passphrasePath

    if not(checkSensitiveFilePermissions(passphrasePath)):
      error "Password file has insecure permissions", key_path = keyStorePath,
            password_path = passphrasePath
    else:
      let rres = readAllChars(passphrasePath)
      if rres.isOk():
        let dres = decryptKeystore(keystore, KeystorePass.init(rres.get()))
        if dres.isOk():
          return dres.get().some()
        else:
          error "Failed to unlock keystore using password file",
                key_path = keystorePath, password_path = passphrasePath
      else:
        error "Failed to read password file", errMsg = ioErrorMsg(rres.error),
              password_path = passphrasePath

  block:
    notice "Trying to unlock keystore using empty password",
           key_path = keystorePath
    let res = decryptKeystore(keystore, KeystorePass.init(""))
    if res.isOk():
      return res.get().some()
    else:
      error "Failed to unlock keystore using empty password",
            key_path = keystorePath

  if NonInteractive in keystoreFlags:
    error "Unable to unlock validator's keystore in non-interactive way!",
          key_name = keyName, key_path = keystorePath
    return

  let prompt = "Please enter password to unlock keystore \"" &
               (validatorsDir / keyName) & "\": "
  let res = keyboardGetPassword[ValidatorPrivKey](prompt, 3,
    proc (password: string): KsResult[ValidatorPrivKey] =
      let decrypted = decryptKeystore(keystore, KeystorePass.init password)
      if decrypted.isErr():
        error "Failed to unlock keystore using provided password. " &
              "Please try again", key_path = keystorePath
      decrypted
  )

  if res.isOk():
    some(res.get())
  else:
    return

iterator validatorKeysFromDirs*(validatorsDir,
                                secretsDir: string): ValidatorPrivKey =
  try:
    for kind, file in walkDir(validatorsDir):
      if kind == pcDir:
        let keyName = splitFile(file).name
        let key = loadKeystore(validatorsDir, secretsDir, keyName, {})
        if key.isSome:
          yield key.get
        else:
          quit 1
  except OSError:
    quit 1

iterator validatorKeys*(conf: BeaconNodeConf|ValidatorClientConf): ValidatorPrivKey =
  let validatorsDir = conf.validatorsDir
  try:
    for kind, file in walkDir(validatorsDir):
      if kind == pcDir:
        let keyName = splitFile(file).name
        let key = loadKeystore(validatorsDir, conf.secretsDir, keyName,
                               conf.getKeystoreFlags())
        if key.isSome:
          yield key.get
        else:
          quit 1
  except OSError as err:
    error "Validator keystores directory not accessible",
          path = validatorsDir, err = err.msg
    quit 1

type
  KeystoreGenerationError = enum
    RandomSourceDepleted,
    FailedToCreateValidatorDir
    FailedToCreateSecretsDir
    FailedToCreateKeystoreFile

proc loadNetKeystore*(keystorePath: string,
                      keystoreFlags: set[KeystoreFlags]): Option[lcrypto.PrivateKey] =

  if not(checkSensitiveFilePermissions(keystorePath)):
    error "Network keystore file has insecure permissions",
          key_path = keyStorePath
    return

  let keystore =
    block:
      let res = NetKeystore.loadStore(keystorePath)
      if res.isOk():
        res.get()
      else:
        return

  if InsecurePassword in keystoreFlags:
    warn "Using insecure password to unlock network keystore",
         key_path = keystorePath
    let decrypted = decryptNetKeystore(keystore,
                                       KeystorePass.init(""))
    if decrypted.isOk:
      return some(decrypted.get())
    else:
      error "Failed to unlock network keystore using insecure password",
            key_path = keystorePath

  if NonInteractive in keystoreFlags:
    error "Unable to unlock network keystore in non-interactive way!",
          key_path = keystorePath
    return

  let prompt = "Please enter password to unlock network keystore: "
  let res = keyboardGetPassword[lcrypto.PrivateKey](prompt, 3,
    proc (password: string): KsResult[lcrypto.PrivateKey] =
      let decrypted = decryptNetKeystore(keystore, KeystorePass.init password)
      if decrypted.isErr():
        error "Failed to unclock network keystore using provided password",
              key_path = keystorePath
      decrypted
  )

  if res.isOk():
    some(res.get())
  else:
    return

proc saveNetKeystore*(rng: var BrHmacDrbgContext, keystorePath: string,
                      netKey: lcrypto.PrivateKey,
                      keystoreFlags: set[KeystoreFlags]): Result[void, KeystoreGenerationError] =
  let password =
    if InsecurePassword in keystoreFlags:
      warn "Using insecure password to lock network keystore",
           key_path = keystorePath
      ""
    else:
      if NonInteractive in keystoreFlags:
        error "Unable to lock network keystore in non-interactive way!",
              key_path = keystorePath
        return err(FailedToCreateKeystoreFile)
      else:
        let prompt = "Please enter NEW password to lock network keystore: "
        let confirm = "Please confirm, network keystore password: "
        let res = keyboardCreatePassword(prompt, confirm)
        if res.isErr():
          return err(FailedToCreateKeystoreFile)
        res.get()

  let keyStore = createNetKeystore(kdfScrypt, rng, netKey,
                                   KeystorePass.init password)
  var encodedStorage: string
  try:
    encodedStorage = Json.encode(keyStore)
  except SerializationError:
    error "Could not serialize network keystore", key_path = keystorePath
    return err(FailedToCreateKeystoreFile)

  let res = secureWriteFile(keystorePath, encodedStorage)
  if res.isOk():
    ok()
  else:
    error "Could not write to network keystore file", key_path = keystorePath
    err(FailedToCreateKeystoreFile)

proc saveKeystore(rng: var BrHmacDrbgContext,
                  validatorsDir: string,
                  signingKey: ValidatorPrivKey, signingPubKey: ValidatorPubKey,
                  signingKeyPath: KeyPath,
                  passopt: Option[KeystorePass],
                  keystoreFlags: set[KeystoreFlags]): Result[void, KeystoreGenerationError] =
  let
    keyName = "0x" & $signingPubKey
    validatorDir = validatorsDir / keyName
    prompt = "Please enter new password to lock keystore: "
    confirm = "Please confirm password: "

  if not existsDir(validatorDir):
    let password =
      if passopt.isSome():
        passopt.get()
      else:
        if InsecurePassword in keystoreFlags:
          KeystorePass.init("")
        else:
          if NonInteractive in keystoreFlags:
            error "Unable to lock keystore in non-interactive way!"
            return err(FailedToCreateKeystoreFile)

          let res = keyboardCreatePassword(prompt, confirm, allowEmpty = true)
          if res.isErr():
            error "Unable to lock keystore in interactive way"
            return err(FailedToCreateKeystoreFile)

          KeystorePass.init(res.get())

    let
      keyStore = createKeystore(kdfPbkdf2, rng, signingKey,
                                password, signingKeyPath)
      keystoreFile = validatorDir / keystoreFileName

    var encodedStorage: string
    try:
      encodedStorage = Json.encode(keyStore)
    except SerializationError:
      error "Could not serialize keystorage", key_path = keystoreFile
      return err(FailedToCreateKeystoreFile)

    let vres = secureCreatePath(validatorDir)
    if vres.isErr():
      return err(FailedToCreateValidatorDir)

    let kwres = secureWriteFile(keystoreFile, encodedStorage)
    if kwres.isErr():
      return err(FailedToCreateKeystoreFile)

  ok()

proc generateDeposits*(preset: RuntimePreset,
                       rng: var BrHmacDrbgContext,
                       seed: KeySeed,
                       firstValidatorIdx, totalNewValidators: int,
                       validatorsDir: string,
                       keystoreFlags: set[KeystoreFlags]): Result[seq[DepositData], KeystoreGenerationError] =
  var deposits: seq[DepositData]

  notice "Generating deposits", totalNewValidators, validatorsDir

  # We'll reuse a single variable here to make the secret
  # scrubbing (burnMem) easier to handle:
  var baseKey = deriveMasterKey(seed)
  defer: burnMem(baseKey)
  baseKey = deriveChildKey(baseKey, baseKeyPath)

  for i in 0 ..< totalNewValidators:
    let validatorIdx = firstValidatorIdx + i

    # We'll reuse a single variable here to make the secret
    # scrubbing (burnMem) easier to handle:
    var derivedKey = baseKey
    defer: burnMem(derivedKey)
    derivedKey = deriveChildKey(derivedKey, validatorIdx)
    derivedKey = deriveChildKey(derivedKey, 0) # This is witdrawal key
    let withdrawalPubKey = derivedKey.toPubKey
    derivedKey = deriveChildKey(derivedKey, 0) # This is the signing key
    let signingPubKey = derivedKey.toPubKey

    ? saveKeystore(rng, validatorsDir,
                   derivedKey, signingPubKey,
                   makeKeyPath(validatorIdx, signingKeyKind),
                   none[KeystorePass](), keystoreFlags)

    deposits.add preset.prepareDeposit(withdrawalPubKey, derivedKey, signingPubKey)

  ok deposits

proc saveWallet*(wallet: Wallet, outWalletPath: string): Result[void, string] =
  let walletDir = splitFile(outWalletPath).dir
  var encodedWallet: string
  try:
    encodedWallet = Json.encode(wallet, pretty = true)
  except SerializationError:
    return err("Could not serialize wallet")

  let pres = secureCreatePath(walletDir)
  if pres.isErr():
    return err("Could not create wallet directory [" & walletDir & "]")
  let wres = secureWriteFile(outWalletPath, encodedWallet)
  if wres.isErr():
    return err("Could not write wallet to file [" & outWalletPath & "]")

  ok()

proc saveWallet*(wallet: WalletPathPair): Result[void, string] =
  saveWallet(wallet.wallet, wallet.path)

proc readPasswordInput(prompt: string, password: var TaintedString): bool =
  try:
    when defined(windows):
      # readPasswordFromStdin() on Windows always returns `false`.
      # https://github.com/nim-lang/Nim/issues/15207
      discard readPasswordFromStdin(prompt, password)
      true
    else:
      readPasswordFromStdin(prompt, password)
  except IOError:
    false

proc setStyleNoError(styles: set[Style]) =
  when defined(windows):
    try: stdout.setStyle(styles)
    except: discard
  else:
    try: stdout.setStyle(styles)
    except IOError, ValueError: discard

proc setForegroundColorNoError(color: ForegroundColor) =
  when defined(windows):
    try: stdout.setForegroundColor(color)
    except: discard
  else:
    try: stdout.setForegroundColor(color)
    except IOError, ValueError: discard

proc resetAttributesNoError() =
  when defined(windows):
    try: stdout.resetAttributes()
    except: discard
  else:
    try: stdout.resetAttributes()
    except IOError: discard

proc importKeystoresFromDir*(rng: var BrHmacDrbgContext,
                             importedDir, validatorsDir: string,
                             keystoreFlags: set[KeystoreFlags]) =
  var password: TaintedString
  defer: burnMem(password)

  try:
    for file in walkDirRec(importedDir):
      let filenameParts = splitFile(file)
      if toLowerAscii(filenameParts.ext) != ".json":
        continue

      # In case we are importing from eth2.0-deposits-cli, the imported
      # validator_keys directory will also include a "deposit_data" file
      # intended for uploading to the launchpad. We'll skip it to avoid
      # the "Invalid keystore" warning that it will trigger.
      if filenameParts.name.startsWith("deposit_data"):
        continue

      let keystore =
        block:
          let res = Keystore.loadStore(file)
          if res.isOk():
            res.get()
          else:
            continue

      var firstDecryptionAttempt = true

      while true:
        var secret: seq[byte]
        let status = decryptCryptoField(keystore.crypto,
                                        KeystorePass.init password,
                                        secret)
        case status
        of Success:
          let privKey = ValidatorPrivKey.fromRaw(secret)
          if privKey.isOk:
            let pubKey = privKey.value.toPubKey
            let status = saveKeystore(rng, validatorsDir, privKey.value, pubKey,
                                      keystore.path,
                                      some(KeystorePass.init(password)),
                                      keystoreFlags)
            if status.isOk:
              notice "Keystore imported", file
            else:
              error "Failed to import keystore", file, err = status.error
          else:
            error "Imported keystore holds invalid key", file, err = privKey.error
          break
        of InvalidKeystore:
          warn "Invalid keystore", file
          break
        of InvalidPassword:
          if firstDecryptionAttempt:
            try:
              const msg = "Please enter the password for decrypting '$1' " &
                          "or press ENTER to skip importing this keystore"
              echo msg % [file]
            except ValueError:
              raiseAssert "The format string above is correct"
          else:
            echo "The entered password was incorrect. Please try again."
          firstDecryptionAttempt = false

          if not readPasswordInput("Password: ", password):
            echo "System error while entering password. Please try again."

          if password.len == 0:
            break
  except OSError:
    fatal "Failed to access the imported deposits directory"
    quit 1

template ask(prompt: string): string =
  try:
    stdout.write prompt, ": "
    stdin.readLine()
  except IOError:
    return err "failure to read data from stdin"

proc pickPasswordAndSaveWallet(rng: var BrHmacDrbgContext,
                               config: BeaconNodeConf,
                               seed: KeySeed): Result[WalletPathPair, string] =
  echoP "When you perform operations with your wallet such as withdrawals " &
        "and additional deposits, you'll be asked to enter a signing " &
        "password. Please note that this password is local to the current " &
        "machine and you can change it at any time."
  echo ""

  var password =
    block:
      let prompt = "Please enter a password: "
      let confirm = "Please repeat the password: "
      let res = keyboardCreatePassword(prompt, confirm)
      if res.isErr():
        return err($res.error)
      res.get()
  defer: burnMem(password)

  var name: WalletName
  let outWalletName = config.outWalletName
  if outWalletName.isSome:
    name = outWalletName.get
  else:
    echoP "For your convenience, the wallet can be identified with a name " &
          "of your choice. Please enter a wallet name below or press ENTER " &
          "to continue with a machine-generated name."
    echo ""

    while true:
      var enteredName = ask "Wallet name"
      if enteredName.len > 0:
        name =
          try:
            WalletName.parseCmdArg(enteredName)
          except CatchableError as err:
            echo err.msg & ". Please try again."
            continue
      break

  let nextAccount =
    if config.cmd == wallets and config.walletsCmd == WalletsCmd.restore:
      config.restoredDepositsCount
    else:
      none Natural

  let wallet = createWallet(kdfPbkdf2, rng, seed,
                            name = name,
                            nextAccount = nextAccount,
                            password = KeystorePass.init password)

  let outWalletFileFlag = config.outWalletFile
  let outWalletFile =
    if outWalletFileFlag.isSome:
      string outWalletFileFlag.get
    else:
      config.walletsDir / addFileExt(string wallet.name, "json")

  let status = saveWallet(wallet, outWalletFile)
  if status.isErr:
    return err("failure to create wallet file due to " & status.error)

  echo "\nWallet file successfully written to \"", outWalletFile, "\""
  return ok WalletPathPair(wallet: wallet, path: outWalletFile)

when defined(windows):
  proc clearScreen =
    discard execShellCmd("cls")
else:
  template clearScreen =
    echo "\e[1;1H\e[2J\e[3J"

proc createWalletInteractively*(
    rng: var BrHmacDrbgContext,
    config: BeaconNodeConf): Result[CreatedWallet, string] =

  if config.nonInteractive:
    return err "not running in interactive mode"

  echoP "The generated wallet is uniquely identified by a seed phrase " &
        "consisting of 24 words. In case you lose your wallet and you " &
        "need to restore it on a different machine, you can use the " &
        "seed phrase to re-generate your signing and withdrawal keys."
  echoP "The seed phrase should be kept secret in a safe location as if " &
        "you are protecting a sensitive password. It can be used to withdraw " &
        "funds from your wallet."
  echoP "We will display the seed phrase on the next screen. Please make sure " &
        "you are in a safe environment and there are no cameras or potentially " &
        "unwanted eye witnesses around you. Please prepare everything necessary " &
        "to copy the seed phrase to a safe location and type 'continue' in " &
        "the prompt below to proceed to the next screen or 'q' to exit now."
  echo ""

  while true:
    let answer = ask "Action"
    if answer.len > 0 and answer[0] == 'q': quit 1
    if answer == "continue": break
    echoP "To proceed to your seed phrase, please type 'continue' (without the quotes). " &
          "Type 'q' to exit now."
    echo ""

  var mnemonic = generateMnemonic(rng)
  defer: burnMem(mnemonic)

  try:
    echoP "Your seed phrase is:"
    setStyleNoError({styleBright})
    setForegroundColorNoError fgCyan
    echoP $mnemonic
    resetAttributesNoError()
  except IOError, ValueError:
    return err "failure to write to the standard output"

  echoP "Press any key to continue."
  try:
    discard getch()
  except IOError as err:
    fatal "Failed to read a key from stdin", err = err.msg
    quit 1

  clearScreen()

  echoP "To confirm that you've saved the seed phrase, please enter the " &
        "first and the last three words of it. In case you've saved the " &
        "seek phrase in your clipboard, we strongly advice clearing the " &
        "clipboard now."
  echo ""

  for i in countdown(2, 0):
    let answer = ask "Answer"
    let parts = answer.split(' ', maxsplit = 1)
    if parts.len == 2:
      if count(parts[1], ' ') == 2 and
         mnemonic.string.startsWith(parts[0]) and
         mnemonic.string.endsWith(parts[1]):
        break
    else:
      doAssert parts.len == 1

    if i > 0:
      echo "\nYour answer was not correct. You have ", i, " more attempts"
      echoP "Please enter 4 words separated with a single space " &
            "(the first word from the seed phrase, followed by the last 3)"
      echo ""
    else:
      quit 1

  clearScreen()

  var mnenomicPassword = KeystorePass.init ""
  defer: burnMem(mnenomicPassword)

  echoP "The recovery of your wallet can be additionally protected by a" &
        "recovery password. Since the seed phrase itself can be considered " &
        "a password, setting such an additional password is optional. " &
        "To ensure the strongest possible security, we recommend writing " &
        "down your seed phrase and remembering your recovery password. " &
        "If you don'n want to set a recovery password, just press ENTER."

  var recoveryPassword = keyboardCreatePassword(
    "Recovery password: ", "Confirm password: ", allowEmpty = true)
  defer:
    if recoveryPassword.isOk:
      burnMem(recoveryPassword.get)

  if recoveryPassword.isErr:
    fatal "Failed to read password from stdin"
    quit 1

  var keystorePass = KeystorePass.init recoveryPassword.get
  defer: burnMem(keystorePass)

  var seed = getSeed(mnemonic, keystorePass)
  defer: burnMem(seed)

  let walletPath = ? pickPasswordAndSaveWallet(rng, config, seed)
  return ok CreatedWallet(walletPath: walletPath, seed: seed)

proc restoreWalletInteractively*(rng: var BrHmacDrbgContext,
                                 config: BeaconNodeConf) =
  var
    enteredMnemonic: TaintedString
    validatedMnemonic: Mnemonic

  defer:
    burnMem enteredMnemonic
    burnMem validatedMnemonic

  echo "To restore your wallet, please enter your backed-up seed phrase."
  while true:
    if not readPasswordInput("Seedphrase: ", enteredMnemonic):
      fatal "failure to read password from stdin"
      quit 1

    if validateMnemonic(enteredMnemonic, validatedMnemonic):
      break
    else:
      echo "The entered mnemonic was not valid. Please try again."

  echoP "If your seed phrase was protected with a recovery password, " &
        "please enter it below. Please ENTER to attempt to restore " &
        "the wallet without a recovery password."

  var recoveryPassword = keyboardCreatePassword(
    "Recovery password: ", "Confirm password: ", allowEmpty = true)
  defer:
    if recoveryPassword.isOk:
      burnMem(recoveryPassword.get)

  if recoveryPassword.isErr:
    fatal "Failed to read password from stdin"
    quit 1

  var keystorePass = KeystorePass.init recoveryPassword.get
  defer: burnMem(keystorePass)

  var seed = getSeed(validatedMnemonic, keystorePass)
  defer: burnMem(seed)

  discard pickPasswordAndSaveWallet(rng, config, seed)

proc unlockWalletInteractively*(wallet: Wallet): Result[KeySeed, string] =
  echo "Please enter the password for unlocking the wallet"

  let res = keyboardGetPassword[KeySeed]("Password: ", 3,
    proc (password: string): KsResult[KeySeed] =
      var secret: seq[byte]
      defer: burnMem(secret)
      let status = decryptCryptoField(wallet.crypto, KeystorePass.init password, secret)
      case status
      of Success:
        ok(KeySeed secret)
      else:
        # TODO Handle InvalidKeystore in a special way here
        let failed = "Unlocking of the wallet failed. Please try again"
        echo failed
        err(failed)
  )

  if res.isOk():
    ok(res.get())
  else:
    err "Unlocking of the wallet failed."

proc loadWallet*(filename: string): Result[Wallet, string] =
  Wallet.loadStore(filename)

proc findWallet*(config: BeaconNodeConf,
                 name: WalletName): Result[Option[WalletPathPair], string] =
  var walletFiles = newSeq[string]()
  try:
    for kind, walletFile in walkDir(config.walletsDir):
      if kind != pcFile: continue
      let walletId = splitFile(walletFile).name
      if cmpIgnoreCase(walletId, name.string) == 0:
        let wallet = ? loadWallet(walletFile)
        return ok some WalletPathPair(wallet: wallet, path: walletFile)
      walletFiles.add walletFile
  except OSError as err:
    return err("Error accessing the wallets directory \"" &
                config.walletsDir & "\": " & err.msg)

  for walletFile in walletFiles:
    let wallet = ? loadWallet(walletFile)
    if cmpIgnoreCase(wallet.name.string, name.string) == 0 or
       cmpIgnoreCase(wallet.uuid.string, name.string) == 0:
      return ok some WalletPathPair(wallet: wallet, path: walletFile)

  return ok none(WalletPathPair)

type
  # This is not particularly well-standardized yet.
  # Some relevant code for generating (1) and validating (2) the data can be found below:
  # 1) https://github.com/ethereum/eth2.0-deposit-cli/blob/dev/eth2deposit/credentials.py
  # 2) https://github.com/ethereum/eth2.0-deposit/blob/dev/src/pages/UploadValidator/validateDepositKey.ts
  LaunchPadDeposit* = object
    pubkey*: ValidatorPubKey
    withdrawal_credentials*: Eth2Digest
    amount*: Gwei
    signature*: ValidatorSig
    deposit_message_root*: Eth2Digest
    deposit_data_root*: Eth2Digest
    fork_version*: Version

func init*(T: type LaunchPadDeposit,
           preset: RuntimePreset, d: DepositData): T =
  T(pubkey: d.pubkey,
    withdrawal_credentials: d.withdrawal_credentials,
    amount: d.amount,
    signature: d.signature,
    deposit_message_root: hash_tree_root(d as DepositMessage),
    deposit_data_root: hash_tree_root(d),
    fork_version: preset.GENESIS_FORK_VERSION)

func `as`*(copied: LaunchPadDeposit, T: type DepositData): T =
  T(pubkey: copied.pubkey,
    withdrawal_credentials: copied.withdrawal_credentials,
    amount: copied.amount,
    signature: copied.signature)
