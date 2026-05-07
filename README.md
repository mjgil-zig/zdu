# zdu

`zdu` computes directory sizes, stores them in xattrs, and then reuses those xattrs for navigation within the same run.

## Cache behavior

By default:

- On every fresh process start, the initial loading screen recomputes directory sizes from the filesystem.
- That initial scan writes directory sizes back to xattrs from the bottom up.
- After the loading screen finishes, in-process navigation does not walk directories again.
- Post-startup navigation reads directory sizes from xattrs only.

With cache enabled:

- `--cache true --ttl <seconds>` allows a fresh process start to trust existing xattrs.
- If an xattr is present and still within the TTL, the initial load may read it directly instead of recomputing that directory.
- If the xattr is missing or expired, the initial load recomputes the directory and writes a fresh xattr.

Delete behavior:

- Deleting a file or directory updates parent directory sizes in memory for the current run.
- The delete path also writes updated xattrs for every parent directory up to the root of the current navigation chain.

## CLI

- `zdu [path]`
- `zdu --cache true --ttl 300 [path]`

`--ttl` is required when `--cache true` is set.
