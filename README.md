# php7.4-extension-builder

[![build](https://github.com/tanshiqi/php7.4-extension-builder/actions/workflows/build.yml/badge.svg)](https://github.com/tanshiqi/php7.4-extension-builder/actions/workflows/build.yml)

Builds extra shared extensions for **statically linked PHP 7.4.33 (NTS / arm64 / API 20190902)**, targeting the `php74` binary shipped with Laravel Herd.

Artifacts:

| File | Kind | php.ini directive |
|---|---|---|
| `opcache.so` | Zend extension | `zend_extension=/abs/path/opcache.so` |
| `ldap.so` | Regular PHP extension | `extension=/abs/path/ldap.so` |

Both are `Mach-O 64-bit bundle arm64` and match Herd's `php74` ABI (`PHP API 20190902,NTS`).

## Why no OpenLDAP install is needed

`ext/ldap` only needs a linkable libldap, and the macOS SDK already provides one:

- `$(xcrun --show-sdk-path)/usr/include/ldap.h`
- `usr/lib/libldap.tbd` → `LDAP.framework` (Apple's OpenLDAP 2.4.28)

`ext/ldap/config.m4` does not use the compiler include search path; it literally checks `test -f $DIR/include/ldap.h` and `test -f $DIR/lib/libldap.*`. The build script therefore creates `build/ldapshim` with symlinks into the SDK so configure can see the header and a library candidate. The resulting `ldap.so` depends only on:

```
/System/Library/Frameworks/LDAP.framework/Versions/A/LDAP
/usr/lib/libSystem.B.dylib
```

Note: Apple's libldap is deprecated. If the framework is ever removed, or modern TLS / SASL is required, rebuild against a Homebrew OpenLDAP instead.

## Local build

```bash
./scripts/build.sh
# artifacts land in dist/
cat dist/SHA256SUMS
```

The script downloads php-7.4.33, creates the SDK shim, configures with `--enable-opcache=shared` and `--with-ldap=shared`, runs `make`, self-checks both modules with the freshly built CLI, and copies them to `dist/`.

Relevant flags:

- `LIBS="-lresolv"`: PHP 7.4's `dns.c` references `res_9_*` (libresolv); without it the CLI target fails to link.
- `-Wno-error=implicit-function-declaration`: PHP 7.4 predates newer clang defaults that treat implicit declarations as errors.

## GitHub Actions

- Push to `main` or run the workflow manually: builds and uploads `dist/` as an artifact.
- Push a `v*` tag: additionally creates a Release with both `.so` files and `SHA256SUMS`.

The runner is pinned to `macos-26`; GitHub-hosted macOS runners are arm64. A preflight step asserts `uname -m` is `arm64` and that the SDK contains `ldap.h` and `libldap.tbd`.

## Installing into Herd (PHP 7.4)

```bash
cp dist/opcache.so dist/ldap.so \
   "$HOME/Library/Application Support/Herd/config/php/74/"
```

Edit `~/Library/Application Support/Herd/config/php/74/php.ini`:

```ini
zend_extension=/Users/<you>/Library/Application Support/Herd/config/php/74/opcache.so
extension=/Users/<you>/Library/Application Support/Herd/config/php/74/ldap.so
```

CLI picks this up immediately; FPM requires a PHP restart (Herd menu Restart, or `SIGUSR2` to the FPM master).

## Verification

```bash
file dist/*.so                     # Mach-O 64-bit bundle arm64
otool -L dist/ldap.so              # must only depend on LDAP.framework / libSystem
php -m | grep -i ldap
php -r 'var_dump(LDAP_OPT_PROTOCOL_VERSION);'                     # int(17)
php -r 'var_dump(opcache_get_status(false)["opcache_enabled"]);'  # true
```
