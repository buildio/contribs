#!/bin/bash
# Ubuntu linux-hwe-7.0 + CVE-2026-98432 fix, built from the Ubuntu source package.
# Runs in docker.io/library/ubuntu:24.04 (amd64). Writes the .debs and SHA256SUMS to $1.
#
# Re-runnable: every step is guarded, so `docker start` on a container that died
# part way through resumes the build instead of starting over. The vmlinux link
# needs ~12 GB; an 8 GB VM is OOM-killed at `LD .tmp_vmlinux1` (exit 137).
#
# Upstream never fixed the 7.0.y series (the fix lands in 6.18.56 and 7.2.10, skipping
# 7.0 and 7.1), and Ubuntu marks linux-hwe-7.0 vulnerable with no fix version. So we
# carry the backport ourselves until Ubuntu ships one.
set -euxo pipefail

OUT=${1:-/out}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=linux-hwe-7.0
BASE=7.0.0-42.42~24.04.1          # noble-updates, the newest released 7.0 HWE kernel
NEW=${BASE}+cve98432.1            # sorts above BASE, below any later Ubuntu respin
FLAVOUR=generic

mkdir -p "$OUT" /work

# -- archive with sources ---------------------------------------------------------
cat > /etc/apt/sources.list.d/kbuild.sources <<EOF
Types: deb deb-src
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
cat > /etc/apt/sources.list.d/kbuild-security.sources <<EOF
Types: deb deb-src
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
rm -f /etc/apt/sources.list.d/ubuntu.sources
export DEBIAN_FRONTEND=noninteractive

# -- toolchain -------------------------------------------------------------------
if [ ! -f /work/.stamp-toolchain ]; then
apt-get update
apt-get install -y --no-install-recommends \
  build-essential fakeroot dpkg-dev devscripts kernel-wedge quilt rsync cpio \
  bc bison flex libssl-dev libelf-dev libncurses-dev libudev-dev libpci-dev \
  libiberty-dev dwarves zstd kmod python3 python3-dev gawk pahole \
  llvm clang lld curl ca-certificates xz-utils
apt-get build-dep -y "$SRC"
touch /work/.stamp-toolchain
fi

# -- source ----------------------------------------------------------------------
cd /work
if [ -z "$(find . -maxdepth 1 -type d -name "${SRC}-*")" ]; then
  apt-get source "$SRC=$BASE"
fi
cd "$(find . -maxdepth 1 -type d -name "${SRC}-*" | head -1)"
test -f debian/debian.env
# shellcheck disable=SC1091
DEBIAN=$(sed -n 's/^DEBIAN=//p' debian/debian.env)
test -n "$DEBIAN"
echo "debian dir: $DEBIAN"

# -- patch -----------------------------------------------------------------------
# Context differs slightly between 7.0 and 7.2 (psp_sk_assoc_free), so allow fuzz,
# then assert on the result instead of trusting the exit status.
if ! grep -q 'kfree_rcu(rcu_dereference_protected(inet->inet_opt, 1), rcu)' net/ipv4/af_inet.c; then
  for p in "$HERE"/patches/*.patch; do
    patch -p1 --fuzz=3 --no-backup-if-mismatch < "$p"
  done
fi
grep -q 'kfree_rcu(rcu_dereference_protected(inet->inet_opt, 1), rcu)' net/ipv4/af_inet.c
grep -q 'kfree_rcu(rcu_dereference_protected(inet_rsk(req)->ireq_opt, 1), rcu)' net/ipv4/tcp_ipv4.c
# Nothing may still free these with a plain kfree().
! grep -q 'kfree(rcu_dereference_protected(inet->inet_opt, 1))' net/ipv4/af_inet.c
! grep -q 'kfree(rcu_dereference_protected(inet_rsk(req)->ireq_opt, 1))' net/ipv4/tcp_ipv4.c
echo "patch verified in source"

# -- version ---------------------------------------------------------------------
# Keep ABI 42 so stock -42 modules, headers and DKMS all still line up. Only the
# package version changes, so `uname -r` stays 7.0.0-42-generic.
cat > /tmp/entry <<EOF
$SRC ($NEW) noble; urgency=medium

  * Backport the fix for CVE-2026-98432 (use-after-free in ip_options_build)

  * ipv4: free inet_opt and ireq_opt after an RCU grace period
    - upstream e3f33b0a1d89d738e2b913dab519226eaf76e15b
    - stable 26d4c36d318cffbbd160884a0e4cec0da4da4936 (v7.2.10)
    - CVE-2026-98432

 -- kernel-cve-backports <kernel-cve-backports@invalid>  $(date -R)

EOF
# Drop any previous entry for this version first, so a re-run always writes the current text
# rather than leaving a stale entry or adding a duplicate.
if head -1 "$DEBIAN/changelog" | grep -qF "$NEW"; then
  awk 'NR > 1 && /^[a-z]/ { rest = 1 } rest' "$DEBIAN/changelog" > /tmp/cl.rest
  test -s /tmp/cl.rest
  mv /tmp/cl.rest "$DEBIAN/changelog"
fi
cat /tmp/entry "$DEBIAN/changelog" > /tmp/changelog && mv /tmp/changelog "$DEBIAN/changelog"
# debian/rules copies $DEBIAN/changelog to debian/changelog on a fresh tree, and
# dh_installchangelogs ships that copy. Refresh it, or a re-run packages the stale one.
cp "$DEBIAN/changelog" debian/changelog
head -3 "$DEBIAN/changelog"
dpkg-parsechangelog -l"$DEBIAN/changelog" -S Version | grep -F "$NEW"

# -- build -----------------------------------------------------------------------
# Image and modules for the generic flavour only. No debug symbols, no tools, no
# DKMS, and no ABI check (the ABI is unchanged, but the reference files are keyed
# to the stock version string).
export skipdbg=true skipabicheck=true skipmodule=true skipretpoline=true
export do_tools=false do_zfs=false do_dkms_nvidia=false do_dkms_nvidia_srv=false
export do_doc_package=false do_source_package=false
# `clean` deletes debian/build, so only ever run it on a fresh tree.
if [ ! -d debian/build ]; then
  fakeroot debian/rules clean
fi
free -g || true
fakeroot debian/rules "binary-$FLAVOUR" -j"$(nproc)"

# -- collect ---------------------------------------------------------------------
cd /work
cp -v ./*.deb "$OUT"/
cd "$OUT"
rm -f SHA256SUMS
sha256sum ./*.deb > SHA256SUMS
# Record the vmlinuz hash too: uname cannot tell this kernel from stock -42.
IMG=$(ls linux-image-unsigned-7.0.0-42-generic_*.deb)
dpkg-deb -x "$IMG" /tmp/img
sha256sum /tmp/img/boot/vmlinuz-* | sed 's|/tmp/img||' >> SHA256SUMS
cat SHA256SUMS
