///|
/// Number of color channels stored per pixel.
#derive(Debug, Eq)
pub(all) enum Channels {
  Rgb
  Rgba
}

///|
/// Number of bytes per pixel: 3 for `Rgb`, 4 for `Rgba`.
pub fn Channels::count(self : Channels) -> Int32 {
  match self {
    Rgb => 3
    Rgba => 4
  }
}

///|
/// Informative only: QOI never transforms pixels based on this value.
#derive(Debug, Eq)
pub(all) enum Colorspace {
  // sRGB with linear alpha
  Srgb
  // all channels linear
  Linear
}

///|
/// A raw, uncompressed image. `pixels` holds `width * height * channels`
/// bytes in row-major order: R, G, B (and A for `Rgba`) per pixel.
#derive(Debug, Eq)
pub(all) struct Image {
  width : Int32
  height : Int32
  channels : Channels
  colorspace : Colorspace
  pixels : Bytes
}

///|
#derive(Debug, Eq)
pub(all) suberror QoiError {
  /// The input ends before the header, the pixel data, or the end marker.
  TooShort
  /// The first four bytes are not `qoif`.
  BadMagic
  /// Invalid width, height, channel count or colorspace.
  BadHeader(String)
  /// `Image::pixels` has the wrong length for the declared dimensions.
  PixelLengthMismatch(expected~ : Int32, actual~ : Int32)
  /// The stream does not end with the 8-byte QOI end marker.
  MissingEndMarker
}

///|
const HEADER_SIZE : Int32 = 14

///|
const END_MARKER_SIZE : Int32 = 8

///|
/// Same limit as the reference implementation (400 million pixels).
const MAX_PIXELS : Int64 = 400000000L

///|
const OP_INDEX : Int32 = 0x00

///|
const OP_DIFF : Int32 = 0x40

///|
const OP_LUMA : Int32 = 0x80

///|
const OP_RUN : Int32 = 0xC0

///|
const OP_RGB : Int32 = 0xFE

///|
const OP_RGBA : Int32 = 0xFF

///|
fn hash_index(r : Int32, g : Int32, b : Int32, a : Int32) -> Int32 {
  (r * 3 + g * 5 + b * 7 + a * 11) % 64
}

///|
/// Difference `cur - prev` of two byte values, wrapped into -128..127.
fn wrap_diff(cur : Int32, prev : Int32) -> Int32 {
  let d = (cur - prev) & 0xFF
  if d >= 128 {
    d - 256
  } else {
    d
  }
}

///|
fn check_dimensions(width : Int32, height : Int32) -> Int32 raise QoiError {
  if width <= 0 || height <= 0 {
    raise QoiError::BadHeader("width and height must be positive")
  }
  let total = width.to_int64() * height.to_int64()
  if total > MAX_PIXELS {
    raise QoiError::BadHeader("image has more than 400 million pixels")
  }
  total.to_int()
}

///|
fn push_u32_be(out : Array[Byte], v : Int32) -> Unit {
  out.push(((v >> 24) & 0xFF).to_byte())
  out.push(((v >> 16) & 0xFF).to_byte())
  out.push(((v >> 8) & 0xFF).to_byte())
  out.push((v & 0xFF).to_byte())
}

///|
fn read_u32_be(data : BytesView, at : Int32) -> Int64 {
  (data[at].to_int64() << 24) |
  (data[at + 1].to_int64() << 16) |
  (data[at + 2].to_int64() << 8) |
  data[at + 3].to_int64()
}

///|
/// Encodes an image as a QOI file.
pub fn encode(image : Image) -> Bytes raise QoiError {
  let n = check_dimensions(image.width, image.height)
  let ch = image.channels.count()
  let expected = n * ch
  if image.pixels.length() != expected {
    raise QoiError::PixelLengthMismatch(expected~, actual=image.pixels.length())
  }
  let out : Array[Byte] = []
  out.push(b'q')
  out.push(b'o')
  out.push(b'i')
  out.push(b'f')
  push_u32_be(out, image.width)
  push_u32_be(out, image.height)
  out.push(ch.to_byte())
  let colorspace_byte = match image.colorspace {
    Srgb => 0
    Linear => 1
  }
  out.push(colorspace_byte.to_byte())
  let index : FixedArray[Int32] = FixedArray::make(256, 0)
  let px = image.pixels
  let mut pr = 0
  let mut pg = 0
  let mut pb = 0
  let mut pa = 255
  let mut run = 0
  for i in 0..<n {
    let o = i * ch
    let r = px[o].to_int()
    let g = px[o + 1].to_int()
    let b = px[o + 2].to_int()
    let a = if ch == 4 { px[o + 3].to_int() } else { pa }
    if r == pr && g == pg && b == pb && a == pa {
      run += 1
      if run == 62 || i == n - 1 {
        out.push((OP_RUN | (run - 1)).to_byte())
        run = 0
      }
    } else {
      if run > 0 {
        out.push((OP_RUN | (run - 1)).to_byte())
        run = 0
      }
      let h = hash_index(r, g, b, a)
      let k = h * 4
      if index[k] == r &&
        index[k + 1] == g &&
        index[k + 2] == b &&
        index[k + 3] == a {
        out.push((OP_INDEX | h).to_byte())
      } else {
        index[k] = r
        index[k + 1] = g
        index[k + 2] = b
        index[k + 3] = a
        if a == pa {
          let vr = wrap_diff(r, pr)
          let vg = wrap_diff(g, pg)
          let vb = wrap_diff(b, pb)
          let vg_r = vr - vg
          let vg_b = vb - vg
          if vr >= -2 && vr <= 1 && vg >= -2 && vg <= 1 && vb >= -2 && vb <= 1 {
            out.push(
              (OP_DIFF | ((vr + 2) << 4) | ((vg + 2) << 2) | (vb + 2)).to_byte(),
            )
          } else if vg >= -32 &&
            vg <= 31 &&
            vg_r >= -8 &&
            vg_r <= 7 &&
            vg_b >= -8 &&
            vg_b <= 7 {
            out.push((OP_LUMA | (vg + 32)).to_byte())
            out.push((((vg_r + 8) << 4) | (vg_b + 8)).to_byte())
          } else {
            out.push(OP_RGB.to_byte())
            out.push(r.to_byte())
            out.push(g.to_byte())
            out.push(b.to_byte())
          }
        } else {
          out.push(OP_RGBA.to_byte())
          out.push(r.to_byte())
          out.push(g.to_byte())
          out.push(b.to_byte())
          out.push(a.to_byte())
        }
      }
      pr = r
      pg = g
      pb = b
      pa = a
    }
  }
  for _ in 0..<7 {
    out.push(b'\x00')
  }
  out.push(b'\x01')
  Bytes::from_array(out)
}

///|
/// Decodes a QOI file. Raises `QoiError` on malformed or truncated input.
pub fn decode(data : BytesView) -> Image raise QoiError {
  if data.length() < HEADER_SIZE + END_MARKER_SIZE {
    raise QoiError::TooShort
  }
  if data[0] != b'q' || data[1] != b'o' || data[2] != b'i' || data[3] != b'f' {
    raise QoiError::BadMagic
  }
  let w64 = read_u32_be(data, 4)
  let h64 = read_u32_be(data, 8)
  if w64 > MAX_PIXELS || h64 > MAX_PIXELS {
    raise QoiError::BadHeader("image dimension is too large")
  }
  let width = w64.to_int()
  let height = h64.to_int()
  let n = check_dimensions(width, height)
  let channels = match data[12].to_int() {
    3 => Channels::Rgb
    4 => Channels::Rgba
    other => raise QoiError::BadHeader("invalid channel count \{other}")
  }
  let colorspace = match data[13].to_int() {
    0 => Colorspace::Srgb
    1 => Colorspace::Linear
    other => raise QoiError::BadHeader("invalid colorspace \{other}")
  }
  let tail = data.length() - END_MARKER_SIZE
  for i in 0..<7 {
    if data[tail + i] != b'\x00' {
      raise QoiError::MissingEndMarker
    }
  }
  if data[tail + 7] != b'\x01' {
    raise QoiError::MissingEndMarker
  }
  let ch = channels.count()
  let pixels : FixedArray[Byte] = FixedArray::make(n * ch, b'\x00')
  let index : FixedArray[Int32] = FixedArray::make(256, 0)
  let mut r = 0
  let mut g = 0
  let mut b = 0
  let mut a = 255
  let mut run = 0
  let mut p = HEADER_SIZE
  for i in 0..<n {
    if run > 0 {
      run -= 1
    } else {
      if p >= tail {
        raise QoiError::TooShort
      }
      let b1 = data[p].to_int()
      p += 1
      if b1 == OP_RGB {
        if p + 3 > tail {
          raise QoiError::TooShort
        }
        r = data[p].to_int()
        g = data[p + 1].to_int()
        b = data[p + 2].to_int()
        p += 3
      } else if b1 == OP_RGBA {
        if p + 4 > tail {
          raise QoiError::TooShort
        }
        r = data[p].to_int()
        g = data[p + 1].to_int()
        b = data[p + 2].to_int()
        a = data[p + 3].to_int()
        p += 4
      } else {
        let tag = b1 & 0xC0
        if tag == OP_INDEX {
          let k = (b1 & 0x3F) * 4
          r = index[k]
          g = index[k + 1]
          b = index[k + 2]
          a = index[k + 3]
        } else if tag == OP_DIFF {
          r = (r + ((b1 >> 4) & 3) - 2) & 0xFF
          g = (g + ((b1 >> 2) & 3) - 2) & 0xFF
          b = (b + (b1 & 3) - 2) & 0xFF
        } else if tag == OP_LUMA {
          if p >= tail {
            raise QoiError::TooShort
          }
          let b2 = data[p].to_int()
          p += 1
          let vg = (b1 & 0x3F) - 32
          r = (r + vg - 8 + ((b2 >> 4) & 0x0F)) & 0xFF
          g = (g + vg) & 0xFF
          b = (b + vg - 8 + (b2 & 0x0F)) & 0xFF
        } else {
          run = b1 & 0x3F
        }
      }
      let k = hash_index(r, g, b, a) * 4
      index[k] = r
      index[k + 1] = g
      index[k + 2] = b
      index[k + 3] = a
    }
    let o = i * ch
    pixels[o] = r.to_byte()
    pixels[o + 1] = g.to_byte()
    pixels[o + 2] = b.to_byte()
    if ch == 4 {
      pixels[o + 3] = a.to_byte()
    }
  }
  {
    width,
    height,
    channels,
    colorspace,
    pixels: pixels.unsafe_reinterpret_as_bytes(),
  }
}

///|
#deprecated
pub extend Channels with Eq::{not_equal, equal}

///|
#deprecated
pub extend Channels with Debug::{to_repr}

///|
#deprecated
pub extend Colorspace with Eq::{not_equal, equal}

///|
#deprecated
pub extend Colorspace with Debug::{to_repr}

///|
#deprecated
pub extend Image with Eq::{not_equal, equal}

///|
#deprecated
pub extend Image with Debug::{to_repr}

///|
#deprecated
pub extend QoiError with Eq::{not_equal, equal}

///|
#deprecated
pub extend QoiError with Debug::{to_repr}