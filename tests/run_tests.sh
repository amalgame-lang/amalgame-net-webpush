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
rm -rf "$TMP"
echo ""
if echo "$OUT" | grep -q '\[FAIL\]'; then
    echo "  RESULT: FAIL"; exit 1
fi
PASS=$(echo "$OUT" | grep -c '\[PASS\]')
echo "  RESULT: PASS ($PASS assertions)"
