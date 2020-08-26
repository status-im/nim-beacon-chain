# Troubleshooting Medalla

As it stands, we are continuously making improvements to both stability and memory usage. So please make sure you keep your client up to date! This means restarting your node and updating your software regularly (we recommend doing this at least once a day). To update and restart, run `git pull`, `make update`, followed by `make medalla`:

```
cd nim-beacon-chain
git pull
make update # Update dependencies
make medalla # Restart using same keys as last run
```

If you find that `make update` causes the console to hang for too long, try running `make update V=1` or `make update V=2` instead (these will print a more verbose output to the console which may make it easier to diagnose the problem).

>**Note:** rest assured that when you restart the beacon node, the software will resume from where it left off, using the validator keys you have already imported.


### Starting over

The directory that stores the blockchain data of the testnet is `build/data/shared_medalla_0` (if you're connecting to another testnet, replace `medalla` with that testnet's name). Delete this folder to start over (for example, if you started building medalla with the wrong private keys).

### Syncing
If you’re experiencing sync problems, or have been running an old version of medalla, we recommend running `make clean-medalla` to restart your sync (make sure you’ve updated to the latest `devel` branch first though).

### Keeping up with the head of the chain

As it stands, logging seems to be slowing down the client,  and quite a few users are experiencing trouble either catching up or keeping up with the head of the chain. You can use the `LOG_LEVEL=INFO` option to reduce verbosity and speed up the client.

```
make LOG_LEVEL=INFO medalla
```

### Low peer counts

If you're experiencing a low peer count, you may be behind a firewall. Try restarting your client and passing `NODE_PARAMS="--nat:\"extip:$EXT_IP_ADDRESS\"` as an option to `make medalla`, where `$EXT_IP_ADDRESS` is your real IP. For example, if your real IP address is `35.124.65.104`, you'd run:

```
make NODE_PARAMS="--nat:\"extip:35.124.65.104\" medalla
```

### Resource leaks

If you're experiencing RAM related resource leaks, try restarting your client (we recommend restarting every 6 hours until we get to the bottom of this issue). If you have a [local Grafana setup](https://github.com/status-im/nim-beacon-chain#getting-metrics-from-a-local-testnet-client), you can try monitoring the severity of these leaks and playing around with the restart interval.
