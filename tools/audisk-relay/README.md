# Audisk Relay

Audisk Relay is the optional loopback transport used by the standalone `index.js` path when Discord's renderer CSP prevents a direct request to the activity backend and the Vencord native helper is unavailable.

## Files

- `audisk-relay.ps1` — PowerShell implementation.
- `audisk-relay.py` — Python implementation.
- `start-relay.cmd` — Windows launcher.

## Run

PowerShell:

```powershell
pwsh ./audisk-relay.ps1
```

Python:

```bash
python ./audisk-relay.py
```

The relay listens on `127.0.0.1:43210` only. It is not intended to accept remote-network traffic.

## Request marker

Audisk requires the `X-Audisk-Relay` marker on relay requests. This prevents an arbitrary browser page from casually driving the local endpoint through a normal cross-origin request.

## When it is needed

You normally do not need the relay when using the Vencord plugin because Audisk can use `VencordNative.pluginHelpers.Audisk` for the same CSP-exempt request path.

Use the relay only for the standalone script when the native helper is not available.

## Security

The relay is deliberately small and loopback-only. Do not expose its port through router forwarding, a public tunnel, a reverse proxy or a permissive firewall rule. Do not add logging that stores OAuth codes, Discord tokens or other private credentials.