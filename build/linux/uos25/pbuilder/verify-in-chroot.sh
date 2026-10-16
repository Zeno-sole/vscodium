#!/bin/sh
# Runs inside the UOS 25 pbuilder chroot.
#
# Installs the VSCodium deb and checks that it is usable on a clean UOS 25
# system: every Depends resolves from the UOS repositories, the launcher and
# desktop entry land in the right places, and - the reason this build needs an
# adaptation at all - no Microsoft apt source is registered.
#
# Usage (from verify-deb.sh): verify-in-chroot.sh <deb-inside-chroot>

set -e

DEB="$1"
if [ ! -f "${DEB}" ]; then
  echo "FAIL: ${DEB} not visible inside the chroot" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> resolving dependencies from the UOS repositories"
apt-get update -y

echo "==> installing $(basename "${DEB}")"
dpkg -i "${DEB}" || {
  echo "==> dpkg left unmet dependencies, resolving with apt"
  apt-get install -y -f
  dpkg -i "${DEB}"
}

echo "==> package metadata"
dpkg -s codium | sed -n '1,20p'

echo "==> files"
for f in /usr/bin/codium /usr/share/codium/codium; do
  if [ ! -e "${f}" ]; then
    echo "FAIL: missing ${f}" >&2
    exit 1
  fi
  echo "    ok ${f}"
done

# The desktop entry is named after product.json's linuxDesktopName, which
# upstream sets to com.visualstudio.CodeOSS, so match on the launcher instead of
# on the file name.
desktop=""
for candidate in /usr/share/applications/*.desktop; do
  if grep -q '^Exec=/usr/share/codium/codium' "${candidate}" 2>/dev/null; then
    desktop="${candidate}"
    break
  fi
done
if [ -z "${desktop}" ]; then
  echo "FAIL: no desktop entry launching /usr/share/codium/codium" >&2
  exit 1
fi
echo "    ok ${desktop}"

echo "==> postinst must not register a Microsoft apt source"
if ls /etc/apt/sources.list.d/ 2>/dev/null | grep -qi 'vscode'; then
  echo "FAIL: postinst wrote an apt source file for vscode" >&2
  exit 1
fi
if grep -rqi 'packages\.microsoft\.com' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
  echo "FAIL: a Microsoft repository is referenced in the apt configuration" >&2
  exit 1
fi
echo "    ok no Microsoft repository registered"

echo "==> apt must still work after installation"
apt-get update -y

echo "==> binary"
/usr/share/codium/codium --version || true

echo "==> VERIFY OK"
