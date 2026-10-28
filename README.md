# contribs

Patched builds of upstream software that Build's nodes run until the fix ships upstream.
Each directory holds the patches and the `build.sh` that produces the artifact. The built
artifacts are attached to GitHub Releases; nodes download them by URL and check the sha256.

| directory | what | why | remove when |
|---|---|---|---|
| [`crun/`](crun/) | crun 1.30.1 + [containers/crun#2402](https://github.com/containers/crun/pull/2402), static x86-64 | On Linux >= 6.16 `crun delete --force` fails with `open pidfd: No such file or directory`; exited containers pile up until PLEG stalls | the crun bundled with CRI-O includes #2402 (first release after 1.30.1) |

## Building

`build.sh` runs inside a container and writes its artifacts and a `SHA256SUMS` file to the
directory given as its first argument.
