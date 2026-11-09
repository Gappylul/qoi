///|
fn rgba_image(width : Int32, height : Int32, pixels : Bytes) -> @qoi.Image {
  {
    width,
    height,
    channels: @qoi.Channels::Rgba,
    colorspace: @qoi.Colorspace::Srgb,
    pixels,
  }
}

///|
/// Deterministic image mixing runs, small diffs, luma diffs and jumps.
fn sample_image(
  width : Int32,
  height : Int32,
  channels : @qoi.Channels,
) -> @qoi.Image {
  let ch = channels.count()
  let pixels : Array[Byte] = []
  for i in 0..<(width * height) {
    pixels.push(((i * 7) & 0xFF).to_byte())
    pixels.push(((i * 13 + i / 16) & 0xFF).to_byte())
    pixels.push(((i / 8 * 5) & 0xFF).to_byte())
    if ch == 4 {
      pixels.push((if i % 50 < 40 { 255 } else { i & 0xFF }).to_byte())
    }
  }
  {
    width,
    height,
    channels,
    colorspace: @qoi.Colorspace::Srgb,
    pixels: Bytes::from_array(pixels),
  }
}

///|
test "header layout" {
  let encoded = @qoi.encode(rgba_image(1, 1, b"\xff\x00\x00\xff"))
  inspect(encoded.length(), content="23")
  inspect(encoded[0].to_int(), content="113") // 'q'
  inspect(encoded[1].to_int(), content="111") // 'o'
  inspect(encoded[2].to_int(), content="105") // 'i'
  inspect(encoded[3].to_int(), content="102") // 'f'
  inspect(encoded[7].to_int(), content="1") // width, big-endian
  inspect(encoded[11].to_int(), content="1") // height, big-endian
  inspect(encoded[12].to_int(), content="4") // channels
  inspect(encoded[13].to_int(), content="0") // colorspace
  inspect(encoded[21].to_int(), content="0") // end marker
  inspect(encoded[22].to_int(), content="1")
}

///|
test "op diff" {
  // (255,0,0) vs (0,0,0): dr = -1 (wrapped), dg = 0, db = 0 -> 0x40|0x10|0x08|0x02
  let encoded = @qoi.encode(rgba_image(1, 1, b"\xff\x00\x00\xff"))
  inspect(encoded[14].to_int(), content="90")
  // (1,255,0): dr = 1, dg = -1 (wrapped), db = 0
  let encoded = @qoi.encode(rgba_image(1, 1, b"\x01\xff\x00\xff"))
  inspect(encoded[14].to_int(), content="118")
}

///|
test "op run" {
  // four pixels equal to the initial previous pixel (0,0,0,255): one run of 4
  let encoded = @qoi.encode(
    rgba_image(
      2, 2, b"\x00\x00\x00\xff\x00\x00\x00\xff\x00\x00\x00\xff\x00\x00\x00\xff",
    ),
  )
  inspect(encoded.length(), content="23")
  inspect(encoded[14].to_int(), content="195") // 0xC0 | (4 - 1)
}

///|
test "op rgb" {
  let encoded = @qoi.encode({
    width: 1,
    height: 1,
    channels: @qoi.Channels::Rgb,
    colorspace: @qoi.Colorspace::Srgb,
    pixels: b"\x0a\xc8\x1e",
  })
  inspect(encoded.length(), content="26")
  inspect(encoded[14].to_int(), content="254")
  inspect(encoded[15].to_int(), content="10")
  inspect(encoded[16].to_int(), content="200")
  inspect(encoded[17].to_int(), content="30")
}

///|
test "op luma" {
  // (100,100,100) needs RGB; then (110,112,108): dg=12, dr-dg=-2, db-dg=-4
  let encoded = @qoi.encode(
    rgba_image(2, 1, b"\x64\x64\x64\xff\x6e\x70\x6c\xff"),
  )
  inspect(encoded.length(), content="28")
  inspect(encoded[14].to_int(), content="254")
  inspect(encoded[18].to_int(), content="172") // 0x80 | (12 + 32)
  inspect(encoded[19].to_int(), content="100") // ((-2 + 8) << 4) | (-4 + 8)
}

///|
test "op index and op rgba" {
  // fully transparent black matches the zero-initialized cache slot 0
  let encoded = @qoi.encode(rgba_image(1, 1, b"\x00\x00\x00\x00"))
  inspect(encoded.length(), content="23")
  inspect(encoded[14].to_int(), content="0")
  // an alpha change that misses the cache needs a full RGBA chunk
  let encoded = @qoi.encode(rgba_image(1, 1, b"\x0a\x14\x1e\x80"))
  inspect(encoded.length(), content="27")
  inspect(encoded[14].to_int(), content="255")
  inspect(encoded[18].to_int(), content="128")
}

///|
test "round trip" {
  for ch in [@qoi.Channels::Rgb, @qoi.Channels::Rgba] {
    for size in [(1, 1), (7, 3), (64, 64), (100, 37)] {
      let (w, h) = size
      let image = sample_image(w, h, ch)
      assert_eq(@qoi.decode(@qoi.encode(image)), image)
    }
  }
}

///|
test "round trip long run" {
  // 200 identical pixels exercise the 62-pixel run limit
  let pixels : Array[Byte] = []
  for _ in 0..<200 {
    pixels.push(b'\x12')
    pixels.push(b'\x34')
    pixels.push(b'\x56')
    pixels.push(b'\xff')
  }
  let image = rgba_image(200, 1, Bytes::from_array(pixels))
  assert_eq(@qoi.decode(@qoi.encode(image)), image)
}

///|
test "linear colorspace round trip" {
  let image : @qoi.Image = {
    width: 1,
    height: 1,
    channels: @qoi.Channels::Rgb,
    colorspace: @qoi.Colorspace::Linear,
    pixels: b"\x01\x02\x03",
  }
  assert_eq(@qoi.decode(@qoi.encode(image)), image)
}

///|
test "decode errors" {
  try @qoi.decode(b"qoif") catch {
    @qoi.QoiError::TooShort => ()
    _ => fail("expected TooShort")
  } noraise {
    _ => fail("expected to fail")
  }
  let encoded = @qoi.encode(rgba_image(1, 1, b"\xff\x00\x00\xff"))
  let bad_magic : Array[Byte] = []
  for i in 0..<encoded.length() {
    bad_magic.push(if i == 0 { b'X' } else { encoded[i] })
  }
  try @qoi.decode(Bytes::from_array(bad_magic)) catch {
    @qoi.QoiError::BadMagic => ()
    _ => fail("expected BadMagic")
  } noraise {
    _ => fail("expected to fail")
  }
  let bad_marker : Array[Byte] = []
  for i in 0..<encoded.length() {
    bad_marker.push(
      if i == encoded.length() - 1 {
        b'\x02'
      } else {
        encoded[i]
      },
    )
  }
  try @qoi.decode(Bytes::from_array(bad_marker)) catch {
    @qoi.QoiError::MissingEndMarker => ()
    _ => fail("expected MissingEndMarker")
  } noraise {
    _ => fail("expected to fail")
  }
}

///|
test "encode rejects bad images" {
  try @qoi.encode(rgba_image(2, 2, b"\x00\x00\x00\xff")) catch {
    @qoi.QoiError::PixelLengthMismatch(expected=16, actual=4) => ()
    _ => fail("expected PixelLengthMismatch")
  } noraise {
    _ => fail("expected to fail")
  }
  try @qoi.encode(rgba_image(0, 1, b"")) catch {
    @qoi.QoiError::BadHeader(_) => ()
    _ => fail("expected BadHeader")
  } noraise {
    _ => fail("expected to fail")
  }
}
