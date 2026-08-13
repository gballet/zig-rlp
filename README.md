# zig-rlp
A zig implementation of RLP

⚠️ Minimum-supported compiler version: ziglang's `0.16.0`

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
