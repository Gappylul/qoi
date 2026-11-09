# Gappylul/qoi

A pure MoonBit encoder and decoder for the
[QOI](https://qoiformat.org) ("Quite OK Image") format. It has no FFI, so it
runs on every backend, including Wasm.

## Usage

```mbt check
///|
test {
  let image : @qoi.Image = {
    width: 1,
    height: 1,
    channels: Rgba,
    colorspace: Srgb,
    pixels: b"\xff\x00\x00\xff",
  }
  let encoded = @qoi.encode(image)
  inspect(encoded.length(), content="23")
  assert_eq(@qoi.decode(encoded), image)
}
```

`decode` raises `QoiError` on bad magic, bad header values, truncated data, or a
missing end marker.

## Credits

The format was designed by Dominic Szablewski. See <https://qoiformat.org> for
the specification and the reference implementation (MIT licensed).