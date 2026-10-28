# crun 1.30.1 + pidfd_open ENOENT fix

crun 1.30.1 is the crun bundled with CRI-O 1.37.2 (`commit: 079ff6a7a16d029460af882f9ea44674e6a510b6`).

Linux 6.16 (`8cf4b738f6d8`, "pidfd: improve uapi when task isn't found") made `pidfd_open()`
return `ENOENT` when the pid is not a thread-group leader. crun 1.30.1 does not handle it, so
after a stopped container's pid is reused by a thread, `crun delete --force` fails with
`open pidfd: No such file or directory` and the container can never be removed.

## Patches

The two commits of [containers/crun#2402](https://github.com/containers/crun/pull/2402)
(merged as `3fc26242`), rebased onto the 1.30.1 tag without changes:

- `8a7fe2e6` linux: treat ENOENT/EINVAL from pidfd_open as ESRCH
- `02e5f710` container: delete: drop EINVAL check after kill

## Build

`build.sh` runs in `docker.io/nixos/nix` and builds `crun-static-amd64` from crun's own
`flake.nix`, as crun's `build-aux/release.sh` does. The commits are applied with a fixed
committer and dates, so the commit that `crun --version` reports is the same on every build.

## Remove

When the crun bundled with CRI-O is a release that contains #2402.
