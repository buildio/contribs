# linux-hwe-7.0 + CVE-2026-98432

`CVE-2026-98432` (CVSS 3.1 **9.8**, `AV:N/AC:L/PR:N/UI:N/C:H/I:H/A:H`) is a use-after-free in
`ip_options_build()`.

`tcp_v4_syn_recv_sock()` hands `ireq->ireq_opt` to the child socket without copying it. Another
CPU can process a retransmitted SYN for the same request socket at the same time and build a
SYNACK from it. Readers only hold `rcu_read_lock()`, but `inet_sock_destruct()` and
`tcp_v4_reqsk_destructor()` free the options with a plain `kfree()`. The options can therefore be
freed while a SYNACK is still being built. Request socket migration
(`net.ipv4.tcp_migrate_req=1`) widens the same race.

Two trigger paths matter in practice:

| Path | Freed object | Reachable by |
|---|---|---|
| `tcp_v4_reqsk_destructor()` | `ireq_opt` | **Remote** — an inbound SYN carrying IPv4 options |
| `inet_sock_destruct()` | `inet_opt` | **Local** — any process calling `setsockopt(IP_OPTIONS)` |

`setsockopt(IP_OPTIONS)` needs no privilege, so dropping options-bearing packets at the network
edge does not close the second path. On a host that runs untrusted workloads, the kernel fix is
the only complete answer.

## Why we carry this ourselves

Upstream fixed the bug in 5.10.272, 5.15.223, 6.1.190, 6.6.159, 6.12.113, 6.18.56, 7.2.10 and
7.3. It **skips 7.0 and 7.1**, which are not maintained stable branches, so no 7.0.y fix will
ever be released. Ubuntu lists `linux-hwe-7.0` as vulnerable with no fix version, and
`linux-hwe-6.14` as ignored because it is end of life.

Remove this directory once Ubuntu ships a `linux-hwe-7.0` that includes the fix.

## Patch

`patches/0001-ipv4-free-inet_opt-and-ireq_opt-after-an-RCU-grace-period.patch`

Eric Dumazet's fix, taken from the 7.2.10 stable commit
`26d4c36d318cffbbd160884a0e4cec0da4da4936` (mainline
`e3f33b0a1d89d738e2b913dab519226eaf76e15b`). It changes two lines, `kfree()` to
`kfree_rcu(..., rcu)`, in `net/ipv4/af_inet.c` and `net/ipv4/tcp_ipv4.c`. `struct ip_options_rcu`
already carries the `rcu` head, and the paths that replace `inet_opt` already use `kfree_rcu()`.

It applies to the 7.0 source with small line offsets and no fuzz. `build.sh` asserts on the
resulting source rather than trusting `patch`'s exit status.

## Build

```sh
docker run --rm --platform linux/amd64 \
  -v "$PWD/kernel:/k:ro" -v "$PWD/out:/out" \
  ubuntu:24.04 bash /k/build.sh /out
```

`debian/control` is untouched, so the packages still carry Ubuntu's kernel team as the
`Maintainer`. The `+cve98432.1` version suffix and the changelog entry are what mark this as an
unofficial build. Ubuntu did not build or test it.

Base is `linux-hwe-7.0 7.0.0-42.42~24.04.1` from `noble-updates` — the newest released 7.0 HWE
kernel, and hundreds of CVEs ahead of the `7.0.0-38` we were running. Output version is
`7.0.0-42.42~24.04.1+cve98432.1`, which sorts above the stock package and below any later Ubuntu
respin, so `apt` will neither downgrade it nor block a real fix later.

Only the `generic` flavour image, modules and headers are built. No debug symbols, no tools, no
DKMS, and the ABI check is skipped because the reference files are keyed to the stock version
string.

Five packages come out:

| package | size | sha256 |
|---|---|---|
| `linux-image-unsigned-7.0.0-42-generic` | 17 MB | `b28833c4934473eaa9eab1ffe4e522dfbef80adf702e749ed8702a8ceaac7c2d` |
| `linux-modules-7.0.0-42-generic` | 166 MB | `0ea4e394130c12cb0d0d65aa6adf540396c4101538e0c49c252de5e4d57079ab` |
| `linux-headers-7.0.0-42-generic` | 4.5 MB | `af5e1d839887eef9c89eece31c5ebcf9f53a371cd7318382de47fc39917cd7c1` |
| `linux-lib-rust-7.0.0-42-generic` | 39 MB | `a0931709e0a1d45419c4e85d87b8a5a690b6275cb73b873d9748cf62cc501fea` |
| `linux-buildinfo-7.0.0-42-generic` | 827 KB | `c57cda3f050e9c736adfc091b041e3afa5ae1dfa90ded34788b6a2875c2e27a4` |

`/boot/vmlinuz-7.0.0-42-generic` inside the image package:
`2a7ee31b2abb4ef4e517d2e10a4eb5b39d81f94b8967eb7ccf4fbd248fca09e0`.

### What is deliberately missing

Stock -38 on these nodes also carries `linux-tools-*`, `linux-main-modules-zfs-*` and
`linux-main-modules-v4l2loopback-*`. This build has none of them, which was checked against
a running host rather than assumed: neither `zfs` nor `v4l2loopback` is loaded, there are no
zpools, `zpool` and `dkms` are not installed, and `perf` is the only thing `linux-tools` would
add. Ubuntu publishes no `linux-modules-extra` for the 7.0 HWE series at all, so nothing moves
into it: `bonding`, `bridge`, `nvme`, `veth`, `overlay`, `vxlan` and `iscsi_tcp` are all in
`linux-modules`, which this build does produce. Losing `bonding` would take `bond0` and the node
with it, so confirm that package installs before you reboot.

The build needs about 12 GB of memory to link `vmlinux`. An 8 GB builder is OOM-killed at
`LD .tmp_vmlinux1` with `Error 137`.

## Installing

The image is unsigned, so Secure Boot has to be off.

`linux-modules` depends on `linux-main-modules-zfs-7.0.0-42-generic` and
`linux-main-modules-v4l2loopback-7.0.0-42-generic`, and `linux-headers` depends on
`linux-hwe-7.0-headers-7.0.0-42`. This build produces none of the three, and `linux-image`
depends on `linux-modules`, so `dpkg -i` on its own fails on unmet dependencies. All three exist
in `noble-updates` at this exact ABI, and our dependencies on them carry no version, so the stock
packages satisfy them.

Fetch those three, then install everything in **one** transaction:

```sh
apt-get download linux-hwe-7.0-headers-7.0.0-42 \
                 linux-main-modules-zfs-7.0.0-42-generic \
                 linux-main-modules-v4l2loopback-7.0.0-42-generic

sudo apt-get install -y --no-install-recommends \
  ./linux-hwe-7.0-headers-7.0.0-42_*_all.deb \
  ./linux-main-modules-zfs-7.0.0-42-generic_*_amd64.deb \
  ./linux-main-modules-v4l2loopback-7.0.0-42-generic_*_amd64.deb \
  ./linux-image-unsigned-7.0.0-42-generic_*+cve98432.1_amd64.deb \
  ./linux-modules-7.0.0-42-generic_*+cve98432.1_amd64.deb \
  ./linux-headers-7.0.0-42-generic_*+cve98432.1_amd64.deb
sudo reboot
```

One transaction matters. The stock zfs package depends on
`linux-image-7.0.0-42-generic | linux-image-unsigned-7.0.0-42-generic`, with no version. Install
it by name on its own and apt satisfies that with the **stock** kernel, leaving two kernels that
both call themselves `7.0.0-42-generic` and a boot menu that may pick the wrong one. Named in the
same command as the image file above, apt binds it to this build instead.

Simulating the command above pulls only `kmod`, `libelf1t64`, `libdw1t64`, `linux-base` and
`wireless-regdb` from the archive, and no stock kernel. Run it with `--simulate` first and
confirm the same.

**The ABI is unchanged, so `uname -r` reads `7.0.0-42-generic`, exactly like the stock kernel.**
That is deliberate — stock modules, headers and DKMS all still match. To tell the two apart,
check the package version or the image hash:

```sh
dpkg-query -W linux-image-unsigned-7.0.0-42-generic   # expect ...+cve98432.1
sha256sum /boot/vmlinuz-7.0.0-42-generic              # compare with SHA256SUMS
```

Confirm the fix reached the binary, not only the source. `kfree_rcu()` compiles to a call to
`kvfree_call_rcu()`, so both freeing paths must show that call and no plain `kfree`:

```sh
objdump -d --disassemble=inet_sock_destruct      debian/build/build-generic/vmlinux | grep call
objdump -d --disassemble=tcp_v4_reqsk_destructor debian/build/build-generic/vmlinux | grep call
```

This build gives `call ... <kvfree_call_rcu>` in both, which is the check that matters. The
source greps alone would pass even if the patch had been reverted by a later step.

Reboot one host at a time, and drain it first. A host crossing from a kernel below 6.16 also
needs the patched crun from [`crun/`](../crun/) before it reboots: on 6.16 and later an unpatched
crun cannot delete a stopped container, so exited containers accumulate until the container
runtime's list outgrows the kubelet's gRPC message limit.
