# amalgame-net-webpush

Web Push (RFC 8030 / 8291 / 8292) sender for the Mosaic / Amalgame stack.

```amalgame
import Amalgame.Net.WebPush

let sub = new PushSubscription(endpoint, p256dh, auth)   // from the browser
let res = WebPush.Send(sub, "{\"title\":\"…\"}", vapidPrivPem, vapidPubB64, "mailto:you@example.com")
// res.Ok / res.StatusCode
```

- **aes128gcm** content-encoding (RFC 8188) + Web Push key derivation
  (RFC 8291: ephemeral ECDH P-256 + HKDF-SHA256 + AES-128-GCM).
- **VAPID** auth (RFC 8292, ES256 JWT).
- Binary HTTPS POST of the encrypted body.

HKDF-SHA256 is pure-Amalgame over `amalgame-crypto`'s `Hmac.Sha256`; the only
FFI is the binary HTTPS POST. The encryption assembly is verified
**byte-exact** against the RFC 8291 Appendix A test vector
(`tests/run_tests.sh`).

Depends on `amalgame-crypto >= 0.8.0` (ECDH + AES-128-GCM) and `amalgame-tls`.
Apache-2.0.
