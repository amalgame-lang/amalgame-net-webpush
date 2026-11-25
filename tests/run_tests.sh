#!/usr/bin/env bash
# run_tests.sh — compile + run the Web Push tests (RFC 8291 Appendix A
# vector). amc switches to library mode when a file literally named
# `facade.am` is among the inputs, so we compile a renamed copy of the
# facade as a normal source alongside the test (which carries Main), with
# the deps (crypto, tls) attached as precompiled archives via the lock.
set -u

# ── Locate amc ─────────────────────────────────────────
if [ $# -ge 1 ]; then AMC="$1";
elif [ -n "${AMC:-}" ]; then :;
elif command -v amc >/dev/null 2>&1; then AMC="$(command -v amc)";
else echo "ERROR: amc not found (arg / AMC env / PATH)." >&2; exit 2; fi
[ -x "$AMC" ] || { echo "ERROR: amc '$AMC' not executable." >&2; exit 2; }
AMC="$(cd "$(dirname "$AMC")" && pwd)/$(basename "$AMC")"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Locate amc runtime + core lib ──────────────────────
AMC_BIN_DIR="$(dirname "$AMC")"
if [ -n "${AMC_RUNTIME:-}" ] && [ -d "$AMC_RUNTIME" ]; then :;
elif [ -d "$AMC_BIN_DIR/../share/amalgame/runtime" ]; then
    AMC_RUNTIME="$(cd "$AMC_BIN_DIR/../share/amalgame/runtime" && pwd)";
elif [ -d "$HOME/.local/share/amalgame/runtime" ]; then
    AMC_RUNTIME="$HOME/.local/share/amalgame/runtime";
else echo "ERROR: amc runtime/ not found (set AMC_RUNTIME)." >&2; exit 2; fi
LIBA="$(dirname "$AMC_RUNTIME")/lib/libamalgame.a"

echo "  amc:     $AMC"
echo "  runtime: $AMC_RUNTIME"

# ── Install deps (crypto v0.8.0 + tls) → lock + cache ──
cd "$PKG"
"$AMC" package add crypto@v0.8.0 >/dev/null 2>&1 || true
"$AMC" package add tls           >/dev/null 2>&1 || true

PKGDIR="${AMALGAME_PACKAGES_DIR:-$HOME/.amalgame/packages}/github.com/amalgame-lang"
CR="$(ls -d "$PKGDIR"/amalgame-crypto/v0.8.0_*/ 2>/dev/null | head -1)"
TLS="$(ls -d "$PKGDIR"/amalgame-tls/*/ 2>/dev/null | sort -V | tail -1)"
[ -n "$CR" ] && [ -n "$TLS" ] || { echo "ERROR: crypto/tls not in cache after package add." >&2; exit 2; }

# ── Build crypto facade → .o ───────────────────────────
# The package archives (build/linux-x86_64/*.a) are gitignored, so they're
# absent after a fresh `package add` in CI. Crypto's facade is pure-AM @c
# (OpenSSL), so we compile it ourselves to a .o (webauthn's pattern).
# TLS needs NO archive: the Amalgame_Tls_* primitives webpush calls are
# `static inline` in Amalgame_Tls.h — header-only, satisfied by -lssl.
TMP="$(mktemp -d)"
( cd "$CR" && "$AMC" --lib -o "$TMP/crypto" facade.am ) >/dev/null 2>&1 \
    || { echo "crypto facade amc compile failed"; exit 1; }
gcc -O2 -I"$AMC_RUNTIME" -I"${CR}runtime" -I"$CR" -w -c "$TMP/crypto.c" -o "$TMP/crypto.o" \
    || { echo "crypto.o build failed"; exit 1; }

# ── Build test (crypto via .o; facade as renamed source) ──
cp "$PKG/facade.am" "$TMP/wp_src.am"
cp "$PKG/tests/webpush_test.am" "$TMP/wp_main.am"
sed -i 's/public static void Main()/public static int Main(string[] args)/' "$TMP/wp_main.am"
# `void Main()` → `int Main(...)`: append a `return 0` before Main's close.
perl -0pi -e 's/(Qulcy4a-fN"\)\n)(    \})/$1        return 0\n$2/' "$TMP/wp_main.am"

echo "── Compiling + linking the RFC 8291 vector test ──"
"$AMC" "$TMP/wp_main.am" "$TMP/wp_src.am" -o "$TMP/test" --quiet || { echo "amc compile failed"; exit 1; }
gcc -O2 -I"$AMC_RUNTIME" -I"${TLS}runtime" -I"${CR}runtime" -w "$TMP/test.c" \
    "$TMP/crypto.o" "$LIBA" -lgc -lm -lcrypto -lssl -o "$TMP/test" \
    || { echo "gcc link failed"; exit 1; }

echo ""
OUT="$("$TMP/test")"
echo "$OUT" | sed 's/^/  /'

# ── v0.1.3 : the push service's certificate name is checked ──
# A fake push service (Python ssl) answers 201 and records the requests ;
# a throwaway CA is trusted through SSL_CERT_FILE. OLD_FACADE=<older
# facade.am>, when given, runs the wrong-name case on it as a witness.
if command -v openssl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    echo ""
    echo "── TLS : certificate of the push service ──"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$TMP/ca.key" -out "$TMP/ca.crt" -subj "/CN=Test CA" >/dev/null 2>&1
    for spec in "localhost DNS:localhost" "other DNS:push.other.test" "ip IP:127.0.0.1"; do
        set -- $spec
        openssl req -newkey rsa:2048 -nodes -keyout "$TMP/$1.key" -out "$TMP/$1.csr" -subj "/CN=$1" >/dev/null 2>&1
        printf "subjectAltName=%s\n" "$2" > "$TMP/$1.ext"
        openssl x509 -req -in "$TMP/$1.csr" -CA "$TMP/ca.crt" -CAkey "$TMP/ca.key" -CAcreateserial -days 1 \
            -extfile "$TMP/$1.ext" -out "$TMP/$1.crt" >/dev/null 2>&1
    done
    cat > "$TMP/push.py" <<'PY'
import socket, ssl, sys
port, cert, key, log = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key)
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(8)
while True:
    c, _ = s.accept()
    try:
        t = ctx.wrap_socket(c, server_side=True)
        data = b""
        while b"\r\n\r\n" not in data:           # the headers, then the whole body
            chunk = t.recv(65536)
            if not chunk: break
            data += chunk
        head, _, body = data.partition(b"\r\n\r\n")
        n = 0
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"): n = int(line.split(b":")[1])
        while len(body) < n:
            chunk = t.recv(65536)
            if not chunk: break
            body += chunk
        open(log, "ab").write(head + b"\r\n\r\n" + body)
        t.sendall(b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        t.close()
    except Exception:
        c.close()
PY
    WPIDS=""
    for spec in "18481 localhost" "18482 other" "18483 ip"; do
        set -- $spec
        python3 "$TMP/push.py" "$1" "$TMP/$2.crt" "$TMP/$2.key" "$TMP/push-$1.log" >/dev/null 2>&1 &
        WPIDS="$WPIDS $!"
    done
    sleep 1
    build_tls() {  # facade.am out
        cp "$1" "$TMP/tv_src.am"; cp "$PKG/tests/tls_verify.am" "$TMP/tv_main.am"
        "$AMC" "$TMP/tv_main.am" "$TMP/tv_src.am" -o "$2" --quiet >/dev/null 2>&1 || return 1
        gcc -O2 -I"$AMC_RUNTIME" -I"${TLS}runtime" -I"${CR}runtime" -w "$2.c" \
            "$TMP/crypto.o" "$LIBA" -lgc -lm -lcrypto -lssl -o "$2"
    }
    TFAIL=0
    tcheck() {  # label expect url
        local o; o="$(SSL_CERT_FILE="$TMP/ca.crt" WP_URL="$3" "$TMP/tv" 2>&1)"; local rc=$?; [ $rc = 0 ] || o="$o (exit $rc)"
        if [ "$o" = "status=$2" ]; then echo "  [PASS] $1"; else echo "  [FAIL] $1 : $o"; TFAIL=1; fi
    }
    if build_tls "$PKG/facade.am" "$TMP/tv"; then
        tcheck "bon nom (localhost) : envoyé (201)" 201 "https://localhost:18481/push/abc"
        tcheck "certificat valide d'un autre nom : refusé (-3)" -3 "https://localhost:18482/push/abc"
        [ -s "$TMP/push-18482.log" ] && { echo "  [FAIL] l'imposteur a reçu la requête"; TFAIL=1; } \
            || echo "  [PASS] l'imposteur n'a rien reçu (ni en-tête VAPID ni message)"
        tcheck "adresse IP, certificat IP:127.0.0.1 : envoyé (201)" 201 "https://127.0.0.1:18483/push/abc"
        tcheck "adresse IP, certificat DNS seulement : refusé (-3)" -3 "https://127.0.0.1:18481/push/abc"
    else
        echo "  [FAIL] build of tests/tls_verify.am"; TFAIL=1
    fi
    if [ -s "${OLD_FACADE:-}" ] && build_tls "$OLD_FACADE" "$TMP/tv_old"; then
        rm -f "$TMP/push-18482.log"
        o="$(SSL_CERT_FILE="$TMP/ca.crt" WP_URL=https://localhost:18482/push/abc "$TMP/tv_old")"
        got=$(grep -c "Authorization: vapid" "$TMP/push-18482.log" 2>/dev/null || true)
        echo "  [TÉMOIN] version précédente, certificat d'un autre nom : $o ; en-tête VAPID reçu par l'imposteur : $([ "${got:-0}" -gt 0 ] && echo OUI || echo non)"
    fi
    for p in $WPIDS; do kill "$p" 2>/dev/null; done
    [ "$TFAIL" = 0 ] || OUT="$OUT
[FAIL] TLS"
    OUT="$OUT
$( [ "$TFAIL" = 0 ] && echo '[PASS] TLS : nom du service vérifié')"
fi
rm -rf "$TMP"
echo ""
if echo "$OUT" | grep -q '\[FAIL\]'; then
    echo "  RESULT: FAIL"; exit 1
fi
PASS=$(echo "$OUT" | grep -c '\[PASS\]')
echo "  RESULT: PASS ($PASS assertions)"
