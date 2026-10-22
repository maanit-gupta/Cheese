# Cheese Share and LocalSend

Cheese Share talks to the open-source [LocalSend](https://localsend.org) app, so Android, iPhone,
Windows, Linux and other Macs running LocalSend can send to and receive from Cheese.

## Protocol version

Implemented from the official spec: **LocalSend Protocol v2.2**,
[`localsend/protocol` README at commit `62bd340`](https://github.com/localsend/protocol/blob/62bd3406ec80d62f2ed46269cdc06c4dcc391083/README.md).
Cheese announces `"version": "2.2"`. The JSON fixtures in `CheeseTests/Fixtures/LocalSend/` are copied
from that README.

| Default | Value |
|---|---|
| Multicast group | `224.0.0.167:53317` (UDP) |
| HTTP port | `53317` (TCP), or any free port if that's taken; the port is announced |
| API prefix | `/api/localsend/v2` |

## What's implemented

| Spec section | Cheese | Where |
|---|---|---|
| 3.1 Multicast discovery: announce, answer with `register`, multicast fallback | ✅ | `Share/LocalSend/Discovery.swift` |
| 3.1/3.2 `POST /register` (being found) | ✅ | `ShareService.route` |
| 4.1 `POST /prepare-upload` (receiving), with per-file tokens | ✅ | `LocalSendReceiver.prepareUpload` |
| 4.2 `POST /upload` (receiving), parallel uploads, `sha256` checked when given (`422` on mismatch) | ✅ | `LocalSendReceiver.upload` |
| 4.3 `POST /cancel` (receiving) | ✅ | `LocalSendReceiver.cancel` |
| 4.1–4.3 the same calls against a peer (sending) | ✅ | `LocalSendSender` |
| Text messages (a single `text/plain` file with its content in `preview`, answered with `204`) | ✅ both ways | `FileInfo.isMessage` |
| 6.1 `GET /info` | ✅ | `ShareService.route` |
| 2. Fingerprint / HTTPS mode: Cheese serves the API over HTTPS with its own certificate, and its fingerprint is that certificate's SHA-256 | ✅ | `TLSIdentity`, `SelfSignedCertificate` |
| HTTPS peers: sending to devices in HTTPS mode, presenting Cheese's certificate as the client certificate and checking theirs against the announced fingerprint | ✅ | `HTTPClient`, `TLSIdentity.matches` |

## Not implemented

- **Client certificates on incoming connections.** In HTTPS mode LocalSend derives a sender's fingerprint
  from its client certificate. Network.framework on macOS can only *require* a client certificate, not
  request one optionally, and requiring it would refuse senders that don't present one. So Cheese
  doesn't ask, and **Always Accept** is keyed by the fingerprint the sender *reports* in
  `prepare-upload`. Transfers are still encrypted; a device on the network could copy another's
  reported fingerprint to skip the prompt.
- **3.2 HTTP legacy discovery** (scanning every address on the subnet). Multicast plus `register` finds
  devices on normal home and office networks; the legacy scan is slow and noisy.
- **5. Reverse transfer / download API** (`prepare-download`, `download`). Cheese announces
  `"download": false`. Phones without LocalSend use Cheese's own browser page instead (below).
- **PINs** (`?pin=`). Cheese asks the user to accept each transfer instead, or trusts the device.
- **Folders.** Cheese sends files, text and links only.

## Cheese's certificate

Made on first use and kept in the Keychain under the label "Cheese Share": a self-signed ECDSA P-256
certificate (SHA-256 signature), valid for ten years, usable for TLS server and client auth. It's
written by `SelfSignedCertificate`, a small DER encoder signed with CryptoKit, rather than with
`swift-certificates`: that package worked but added 6.9 MB to the app, against v3's 2 MB budget, so the
author chose to hand-write the one certificate Cheese needs. Its fingerprint (SHA-256 of the DER,
lowercase hex) is shown in Settings → Share. If the Keychain won't store it, Cheese falls back to HTTP
mode with a random fingerprint and Settings says the connection is unencrypted.

## Cheese's browser page (not part of LocalSend)

The Phone (scan QR) tile serves `http://<mac-ip>:<port>/<128-bit token>/` from a second, plain-HTTP
listener on its own port, because phone browsers refuse self-signed certificates (the spec's section 5
notes the same):

| Route | Does |
|---|---|
| `GET /<token>/` | The page (self-contained HTML, no remote resources) |
| `GET /<token>/items` | What the Mac offers, as JSON |
| `GET /<token>/download/<id>` | One offered file or text |
| `POST /<token>/upload?name=<file name>` | A file from the phone, raw body |
| `POST /<token>/text` | Text from the phone, onto the Mac's clipboard |

Scanning the QR code is the consent: uploads during that session aren't prompted. A new token is
made every time Cheese Share starts, so old links stop working.

## Limits and safety

- Nothing listens until the Share panel opens; everything stops 10 minutes after it closes (later if a
  transfer is still running), or at once when the Share module is turned off.
- The server binds to the Mac's LAN address only, never `0.0.0.0`.
- Transfers over the configured limit (default 10 GB) are refused with `403`. Uploads larger than
  announced are cut off. A transfer that's quiet for 2 minutes expires, and partial files are deleted.
- Every `upload` must carry the session ID, file ID and token from `prepare-upload`, from the sender's
  IP address. Anything else is `403`; a second file upload is `409`; a second session while one is
  running is `409`.
- File names are sanitized (`FilenameSanitizer`): last path component only, no `..`, no hidden names,
  no control characters, at most 255 bytes, and never overwriting (`OutputNamer` numbers collisions).
  Files are written as hidden partial files in the destination and renamed only once complete.
