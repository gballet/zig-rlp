# zig-rlp
A zig implementation of RLP

⚠️ Minimum-supported compiler version: ziglang's `0.17.0`

## Language compatibility table

Each entry in this table tells the last supported version for each zig compiler version.

|Release|Zig version|
|-|-|
|0.1.3|0.16.0|

## Testing

```sh
zig build test
```

On top of the unit tests, the suite runs the official Ethereum RLP vectors
(`RLPTests/rlptest.json` and `RLPTests/invalidRLPTest.json`) from the
`ethereum-tests` submodule. They run when the submodule is checked out and are
skipped when it is not, so a plain clone still builds and tests the library:

```sh
git submodule update --init --depth 1 ethereum-tests
```

The submodule is marked shallow, so this is a ~280 MB checkout rather than the
full ~800 MB history. CI clones it on the first run and restores it from the
Actions cache from then on.

## Benchmarking

`zig build bench` installs `zig-out/bin/rlp-bench`, which serializes and
deserializes a mainnet-shaped block (header, 200 transactions, 2 uncles,
~44.6 KB encoded). It builds with `-Doptimize=fast` unless another optimized
mode is requested, and links libc so allocations go through malloc.

```sh
rlp-bench [all|serialize|deserialize] [iterations]   # defaults: all, 5000
```

Compare two builds with [poop](https://github.com/andrewrk/poop) by keeping a
copy of the binary from before a change:

```sh
zig build bench && cp zig-out/bin/rlp-bench /tmp/rlp-bench-before
# ...make the change...
zig build bench
poop '/tmp/rlp-bench-before serialize' 'zig-out/bin/rlp-bench serialize'
```
