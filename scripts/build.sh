#!/usr/bin/env bash
#
# Builds PHP 7.4.33 shared extensions for static PHP builds such as Laravel Herd:
#
#   modules/opcache.so   (Zend extension; zend_extension=...)
#   modules/ldap.so      (normal extension; extension=...)
#
# Target ABI: PHP 7.4.33, NTS (non-ZTS), arm64, API 20190902.
# ldap links against Apple's LDAP.framework (OpenLDAP 2.4.28) shipped with the
# macOS SDK, so no Homebrew/OpenLDAP install is required.
set -euo pipefail

PHP_VERSION=7.4.33
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
SDK="$(xcrun --show-sdk-path)"
NPROC="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

mkdir -p "$BUILD"
rm -rf "$DIST"
mkdir -p "$DIST"

cd "$BUILD"

if [ ! -f "php-$PHP_VERSION.tar.gz" ]; then
  curl -fsSLO "https://www.php.net/distributions/php-$PHP_VERSION.tar.gz"
fi
if [ ! -d "php-$PHP_VERSION" ]; then
  tar xf "php-$PHP_VERSION.tar.gz"
fi

# ext/ldap/config.m4 only looks for real files on disk (it does not use the
# compiler's include search path), while the macOS SDK ships ldap.h plus a
# libldap.tbd stub that resolves to LDAP.framework. Link the SDK into a small
# shim tree so configure can see both the header and a library candidate.
SHIM="$BUILD/ldapshim"
rm -rf "$SHIM"
mkdir -p "$SHIM/lib"
ln -s "$SDK/usr/include" "$SHIM/include"
ln -s "$SDK/usr/lib/libldap.tbd" "$SHIM/lib/libldap.tbd"
ln -s "$SDK/usr/lib/libldap.tbd" "$SHIM/lib/libldap.3.dylib"

cd "$BUILD/php-$PHP_VERSION"

# - LIBS=-lresolv: PHP 7.4's dns.c references res_9_* which live in libresolv
#   on macOS; without it the CLI target fails to link (the extension modules
#   still build, but a clean build lets us use the CLI for verification).
# - -Wno-error=implicit-function-declaration: PHP 7.4 sources predate the
#   newer clang default of treating implicit declarations as errors.
CFLAGS="-O2 -Wno-error=implicit-function-declaration" LIBS="-lresolv" ./configure \
  --disable-all \
  --enable-cli \
  --disable-cgi \
  --disable-phpdbg \
  --without-pear \
  --enable-opcache=shared \
  "--with-ldap=shared,$SHIM"

make -j"$NPROC"

# Self-check with the freshly built CLI: both modules must load and register.
./sapi/cli/php -n -d zend_extension="$PWD/modules/opcache.so" \
  -r 'exit(function_exists("opcache_get_status") ? 0 : 1);'
./sapi/cli/php -n -d extension="$PWD/modules/ldap.so" \
  -r 'exit(LDAP_OPT_PROTOCOL_VERSION === 17 && function_exists("ldap_connect") ? 0 : 1);'

cp modules/opcache.so modules/ldap.so "$DIST/"
cd "$DIST"
shasum -a 256 ./*.so > SHA256SUMS

echo
echo "Artifacts:"
cat SHA256SUMS
