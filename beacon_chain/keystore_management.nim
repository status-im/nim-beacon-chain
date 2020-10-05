import
  std/[os, strutils, terminal, wordwrap],
  chronicles, chronos, web3, stint, json_serialization, stew/byteutils,
  serialization, blscurve, eth/common/eth_types, eth/keys, confutils, bearssl,
  spec/[datatypes, digest, crypto, keystore],
  stew/io2, libp2p/crypto/crypto as lcrypto,
  nimcrypto/utils as ncrutils,
  conf, ssz/merkleization, network_metadata

export
  keystore

{.push raises: [Defect].}

const
  keystoreFileName* = "keystore.json"
  netKeystoreFileName* = "network_keystore.json"

type
  WalletPathPair* = object
    wallet*: Wallet
    path*: string

  CreatedWallet* = object
    walletPath*: WalletPathPair
    mnemonic*: Mnemonic

const
  minPasswordLen = 10

  mostCommonPasswords = wordListArray(
    currentSourcePath.parentDir /
      "../vendor/nimbus-security-resources/passwords/10-million-password-list-top-100000.txt",
    minWordLen = minPasswordLen)

template echo80(msg: string) =
  echo wrapWords(msg, 80)

proc loadKeystore(validatorsDir, secretsDir, keyName: string,
                  nonInteractive: bool): Option[ValidatorPrivKey] =
  let
    keystorePath = validatorsDir / keyName / keystoreFileName
    keystore =
      try: Json.loadFile(keystorePath, Keystore)
      except IOError as err:
        error "Failed to read keystore", err = err.msg, path = keystorePath
        return
      except SerializationError as err:
        error "Invalid keystore", err = err.formatMsg(keystorePath)
        return

  let passphrasePath = secretsDir / keyName
  if fileExists(passphrasePath):
    let
      passphrase = KeystorePass:
        try: readFile(passphrasePath)
        except IOError as err:
          error "Failed to read passphrase file", err = err.msg, path = passphrasePath
          return

    let res = decryptKeystore(keystore, passphrase)
    if res.isOk:
      return res.get.some
    else:
      error "Failed to decrypt keystore", keystorePath, passphrasePath
      return

  if nonInteractive:
    error "Unable to load validator key store. Please ensure matching passphrase exists in the secrets dir",
      keyName, validatorsDir, secretsDir = secretsDir
    return

  var remainingAttempts = 3
  var prompt = "Please enter passphrase for key \"" & validatorsDir/keyName & "\"\n"
  while remainingAttempts > 0:
    let passphrase = KeystorePass:
      try: readPasswordFromStdin(prompt)
      except IOError:
        error "STDIN not readable. Cannot obtain Keystore password"
        return

    let decrypted = decryptKeystore(keystore, passphrase)
    if decrypted.isOk:
      return decrypted.get.some
    else:
      prompt = "Keystore decryption failed. Please try again"
      dec remainingAttempts

iterator validatorKeysFromDirs*(validatorsDir, secretsDir: string): ValidatorPrivKey =
  try:
    for kind, file in walkDir(validatorsDir):
      if kind == pcDir:
        let keyName = splitFile(file).name
        let key = loadKeystore(validatorsDir, secretsDir, keyName, true)
        if key.isSome:
          yield key.get
        else:
          quit 1
  except OSError:
    quit 1

iterator validatorKeys*(conf: BeaconNodeConf|ValidatorClientConf): ValidatorPrivKey =
  for validatorKeyFile in conf.validators:
    try:
      yield validatorKeyFile.load
    except CatchableError as err:
      error "Failed to load validator private key",
            file = validatorKeyFile.string, err = err.msg
      quit 1

  let validatorsDir = conf.validatorsDir
  try:
    for kind, file in walkDir(validatorsDir):
      if kind == pcDir:
        let keyName = splitFile(file).name
        let key = loadKeystore(validatorsDir, conf.secretsDir, keyName, conf.nonInteractive)
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
    FailedToCreateSecretFile
    FailedToCreateKeystoreFile

proc loadNetKeystore*(keyStorePath: string,
                      insecurePwd: Option[string]): Option[lcrypto.PrivateKey] =
  when defined(windows):
    # Windows do not support per-user permissions, skiping verification part.
    discard
  else:
    let allowedMask = {UserRead, UserWrite}
    let mask = {UserExec,
                GroupRead, GroupWrite, GroupExec,
                OtherRead, OtherWrite, OtherExec}
    let pres = getPermissionsSet(keyStorePath)
    if pres.isErr():
      error "Could not check key file permissions",
            key_path = keyStorePath, errorCode = $pres.error,
            errorMsg = ioErrorMsg(pres.error)
      return

    let insecurePermissions = pres.get() * mask
    if insecurePermissions != {}:
      error "Network key file has insecure permissions",
            key_path = keyStorePath,
            insecure_permissions = $insecurePermissions,
            current_permissions = pres.get().toString(),
            required_permissions = allowedMask.toString()
      return

  let keyStore =
    try:
      Json.loadFile(keystorePath, NetKeystore)
    except IOError as err:
      error "Failed to read network keystore", err = err.msg,
            path = keystorePath
      return
    except SerializationError as err:
      error "Invalid network keystore", err = err.formatMsg(keystorePath)
      return

  if insecurePwd.isSome():
    warn "Using insecure password to unlock networking key"
    let decrypted = decryptNetKeystore(keystore, KeystorePass insecurePwd.get())
    if decrypted.isOk:
      return some(decrypted.get())
    else:
      error "Network keystore decryption failed", key_store = keyStorePath
      return
  else:
    var remainingAttempts = 3
    var counter = 0
    var prompt = "Please enter passphrase to unlock networking key: "
    while remainingAttempts > 0:
      let passphrase = KeystorePass:
        try:
          readPasswordFromStdin(prompt)
        except IOError:
          error "Could not read password from stdin"
          return

      let decrypted = decryptNetKeystore(keystore, passphrase)
      if decrypted.isOk:
        return some(decrypted.get())
      else:
        dec remainingAttempts
        inc counter
        os.sleep(1000 * counter)
        error "Network keystore decryption failed", key_store = keyStorePath

proc saveNetKeystore*(rng: var BrHmacDrbgContext, keyStorePath: string,
                      netKey: lcrypto.PrivateKey, insecurePwd: Option[string]
                     ): Result[void, KeystoreGenerationError] =
  var password, confirmedPassword: TaintedString
  if insecurePwd.isSome():
    warn "Using insecure password to lock networking key"
    password = insecurePwd.get()
  else:
    while true:
      let prompt = "Please enter NEW password to lock network key storage: "

      password =
        try:
          readPasswordFromStdin(prompt)
        except IOError:
          error "Could not read password from stdin"
          return err(FailedToCreateKeystoreFile)

      if len(password) < minPasswordLen:
        echo "The entered password should be at least ", minPasswordLen,
             " characters"
        continue
      elif password in mostCommonPasswords:
        echo80 "The entered password is too commonly used and it would be " &
               "easy to brute-force with automated tools."
        continue

      confirmedPassword =
        try:
          readPasswordFromStdin("Please confirm, network key storage " &
                                "password: ")
        except IOError:
          error "Could not read password from stdin"
          return err(FailedToCreateKeystoreFile)

      if password != confirmedPassword:
        echo "Passwords don't match, please try again"
        continue

      break

  let keyStore = createNetKeystore(kdfScrypt, rng, netKey,
                                   KeystorePass password)
  var encodedStorage: string
  try:
    encodedStorage = Json.encode(keyStore)
  except SerializationError:
    return err(FailedToCreateKeystoreFile)

  let res = writeFile(keyStorePath, encodedStorage, 0o600)
  if res.isOk():
    ok()
  else:
    err(FailedToCreateKeystoreFile)

proc saveKeystore(rng: var BrHmacDrbgContext,
                  validatorsDir, secretsDir: string,
                  signingKey: ValidatorPrivKey, signingPubKey: ValidatorPubKey,
                  signingKeyPath: KeyPath): Result[void, KeystoreGenerationError] =
  let
    keyName = "0x" & $signingPubKey
    validatorDir = validatorsDir / keyName

  if not existsDir(validatorDir):
    var password = KeystorePass ncrutils.toHex(getRandomBytes(rng, 32))
    defer: burnMem(password)

    let
      keyStore = createKeystore(kdfPbkdf2, rng, signingKey,
                                password, signingKeyPath)
      keystoreFile = validatorDir / keystoreFileName

    try: createDir validatorDir
    except OSError, IOError: return err FailedToCreateValidatorDir

    try: createDir secretsDir
    except OSError, IOError: return err FailedToCreateSecretsDir

    try: writeFile(secretsDir / keyName, password.string)
    except IOError: return err FailedToCreateSecretFile

    try: Json.saveFile(keystoreFile, keyStore)
    except IOError, SerializationError:
      return err FailedToCreateKeystoreFile

  ok()

proc generateDeposits*(preset: RuntimePreset,
                       rng: var BrHmacDrbgContext,
                       mnemonic: Mnemonic,
                       firstValidatorIdx, totalNewValidators: int,
                       validatorsDir: string,
                       secretsDir: string): Result[seq[DepositData], KeystoreGenerationError] =
  var deposits: seq[DepositData]

  notice "Generating deposits", totalNewValidators, validatorsDir, secretsDir

  let withdrawalKeyPath = makeKeyPath(0, withdrawalKeyKind)
  # TODO: Explain why we are using an empty password
  var withdrawalKey = keyFromPath(mnemonic, KeystorePass"", withdrawalKeyPath)
  defer: burnMem(withdrawalKey)
  let withdrawalPubKey = withdrawalKey.toPubKey

  for i in 0 ..< totalNewValidators:
    let keyStoreIdx = firstValidatorIdx + i
    let signingKeyPath = withdrawalKeyPath.append keyStoreIdx
    var signingKey = deriveChildKey(withdrawalKey, keyStoreIdx)
    defer: burnMem(signingKey)
    let signingPubKey = signingKey.toPubKey

    ? saveKeystore(rng, validatorsDir, secretsDir,
                   signingKey, signingPubKey, signingKeyPath)

    deposits.add preset.prepareDeposit(withdrawalPubKey, signingKey, signingPubKey)

  ok deposits

proc saveWallet*(wallet: Wallet, outWalletPath: string): Result[void, string] =
  try: createDir splitFile(outWalletPath).dir
  except OSError, IOError:
    let e = getCurrentException()
    return err("failure to create wallet directory: " & e.msg)

  try: Json.saveFile(outWalletPath, wallet, pretty = true)
  except IOError as e:
    return err("failure to write file: " & e.msg)
  except SerializationError as e:
    # TODO: Saving a wallet should not produce SerializationErrors.
    # Investigate the source of this exception.
    return err("failure to serialize wallet: " & e.formatMsg("wallet"))

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
                             importedDir, validatorsDir, secretsDir: string) =
  var password: TaintedString
  defer: burnMem(password)

  try:
    for file in walkDirRec(importedDir):
      let ext = splitFile(file).ext
      if toLowerAscii(ext) != ".json":
        continue

      let keystore = try:
        Json.loadFile(file, Keystore)
      except SerializationError as e:
        warn "Invalid keystore", err = e.formatMsg(file)
        continue
      except IOError as e:
        warn "Failed to read keystore file", file, err = e.msg
        continue

      var firstDecryptionAttempt = true

      while true:
        var secret = decryptCryptoField(keystore.crypto, KeystorePass password)

        if secret.len == 0:
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
        else:
          let privKey = ValidatorPrivKey.fromRaw(secret)
          if privKey.isOk:
            let pubKey = privKey.value.toPubKey
            let status = saveKeystore(rng, validatorsDir, secretsDir,
                                      privKey.value, pubKey,
                                      keystore.path)
            if status.isOk:
              notice "Keystore imported", file
            else:
              error "Failed to import keystore", file, err = status.error
          else:
            error "Imported keystore holds invalid key", file, err = privKey.error
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
                               mnemonic: Mnemonic): Result[WalletPathPair, string] =
  echo ""
  echo80 "When you perform operations with your wallet such as withdrawals " &
         "and additional deposits, you'll be asked to enter a password. " &
         "Please note that this password is local to the current Nimbus " &
         "installation and can be changed at any time."
  echo ""

  while true:
    var password, confirmedPassword: TaintedString
    try:
      var firstTry = true

      template prompt: string =
        if firstTry:
          "Please enter a password: "
        else:
          "Please enter a new password: "

      while true:
        if not readPasswordInput(prompt, password):
          return err "failure to read a password from stdin"

        if password.len < minPasswordLen:
          try:
            echo "The entered password should be at least $1 characters." %
                 [$minPasswordLen]
          except ValueError:
            raiseAssert "The format string above is correct"
        elif password in mostCommonPasswords:
          echo80 "The entered password is too commonly used and it would be easy " &
                 "to brute-force with automated tools."
        else:
          break

        firstTry = false

      if not readPasswordInput("Please repeat the password:", confirmedPassword):
        return err "failure to read a password from stdin"

      if password != confirmedPassword:
        echo "Passwords don't match, please try again"
        continue

      var name: WalletName
      let outWalletName = config.outWalletName
      if outWalletName.isSome:
        name = outWalletName.get
      else:
        echo ""
        echo80 "For your convenience, the wallet can be identified with a name " &
               "of your choice. Please enter a wallet name below or press ENTER " &
               "to continue with a machine-generated name."

        while true:
          var enteredName = ask "Wallet name"
          if enteredName.len > 0:
            name = try: WalletName.parseCmdArg(enteredName)
                   except CatchableError as err:
                     echo err.msg & ". Please try again."
                     continue
          break

      let nextAccount = if config.cmd == wallets and
                           config.walletsCmd == WalletsCmd.restore:
        config.restoredDepositsCount
      else:
        none Natural

      let wallet = createWallet(kdfPbkdf2, rng, mnemonic,
                                name = name,
                                nextAccount = nextAccount,
                                password = KeystorePass password)

      let outWalletFileFlag = config.outWalletFile
      let outWalletFile = if outWalletFileFlag.isSome:
        string outWalletFileFlag.get
      else:
        config.walletsDir / addFileExt(string wallet.uuid, "json")

      let status = saveWallet(wallet, outWalletFile)
      if status.isErr:
        return err("failure to create wallet file due to " & status.error)

      notice "Wallet file written", path = outWalletFile
      return ok WalletPathPair(wallet: wallet, path: outWalletFile)
    finally:
      burnMem(password)
      burnMem(confirmedPassword)

proc createWalletInteractively*(
    rng: var BrHmacDrbgContext,
    config: BeaconNodeConf): Result[CreatedWallet, string] =

  if config.nonInteractive:
    return err "not running in interactive mode"

  var mnemonic = generateMnemonic(rng)
  defer: burnMem(mnemonic)

  echo80 "The generated wallet is uniquely identified by a seed phrase " &
         "consisting of 24 words. In case you lose your wallet and you " &
         "need to restore it on a different machine, you must use the " &
         "words displayed below:"

  try:
    echo ""
    setStyleNoError({styleBright})
    setForegroundColorNoError fgCyan
    echo80 $mnemonic
    resetAttributesNoError()
    echo ""
  except IOError, ValueError:
    return err "failure to write to the standard output"

  echo80 "Please back up the seed phrase now to a safe location as " &
         "if you are protecting a sensitive password. The seed phrase " &
         "can be used to withdraw funds from your wallet."

  echo ""
  echo "Did you back up your seed recovery phrase?\p" &
       "(please type 'yes' to continue or press enter to quit)"

  while true:
    let answer = ask "Answer"
    if answer == "":
      return err "aborted wallet creation"
    elif answer != "yes":
      echo "To continue, please type 'yes' (without the quotes) or press enter to quit"
    else:
      break

  let walletPath = ? pickPasswordAndSaveWallet(rng, config, mnemonic)
  return ok CreatedWallet(walletPath: walletPath, mnemonic: mnemonic)

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
    if not readPasswordInput("Seedphrase:", enteredMnemonic):
      fatal "failure to read password from stdin"
      quit 1

    if validateMnemonic(enteredMnemonic, validatedMnemonic):
      break
    else:
      echo "The entered mnemonic was not valid. Please try again."

  discard pickPasswordAndSaveWallet(rng, config, validatedMnemonic)

proc loadWallet*(fileName: string): Result[Wallet, string] =
  try:
    ok Json.loadFile(fileName, Wallet)
  except CatchableError as e:
    err e.msg

proc unlockWalletInteractively*(wallet: Wallet): Result[Mnemonic, string] =
  echo "Please enter the password for unlocking the wallet"

  for i in 1..3:
    var password: TaintedString
    try:
      if not readPasswordInput("Password: ", password):
        return err "failure to read password from stdin"

      var secret = decryptCryptoField(wallet.crypto, KeystorePass password)
      if secret.len > 0:
        defer: burnMem(secret)
        return ok Mnemonic(string.fromBytes(secret))
      else:
        echo "Unlocking of the wallet failed. Please try again."
    finally:
      burnMem(password)

  return err "failure to unlock wallet"

proc findWallet*(config: BeaconNodeConf, name: WalletName): Result[WalletPathPair, string] =
  var walletFiles = newSeq[string]()

  try:
    for kind, walletFile in walkDir(config.walletsDir):
      if kind != pcFile: continue
      let walletId = splitFile(walletFile).name
      if cmpIgnoreCase(walletId, name.string) == 0:
        let wallet = ? loadWallet(walletFile)
        return ok WalletPathPair(wallet: wallet, path: walletFile)
      walletFiles.add walletFile
  except OSError:
    return err "failure to list wallet directory"

  for walletFile in walletFiles:
    let wallet = ? loadWallet(walletFile)
    if cmpIgnoreCase(wallet.name.string, name.string) == 0:
      return ok WalletPathPair(wallet: wallet, path: walletFile)

  return err "failure to locate wallet file"

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
