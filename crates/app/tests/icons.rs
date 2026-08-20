//! The icons `tauri.conf.json` bundles.
//!
//! Nothing else in this repo ever opens these files, so a stale one — or a
//! wrongly regenerated one — ships with every check green.

use std::path::{Path, PathBuf};

/// The mark's colour, the lime the kendex wordmark uses. The mark covers
/// about a fifth of a near-black field, so the share of this colour an
/// image carries says whether it is the mark, without pinning a pixel.
const LIME: [u8; 3] = [0xCC, 0xFF, 0x00];

fn app_crate() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

/// The bundled set, read from the config rather than listed here: an icon
/// added to the bundle and never generated is exactly the gap this closes.
#[allow(clippy::expect_used)]
fn configured_icons() -> Vec<String> {
    let config: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(app_crate().join("tauri.conf.json")).expect("tauri.conf.json"),
    )
    .expect("tauri.conf.json parses");
    let icons = config["bundle"]["icon"]
        .as_array()
        .expect("bundle.icon is a list")
        .iter()
        .map(|path| path.as_str().expect("icon paths are strings").to_owned())
        .collect::<Vec<_>>();
    assert!(!icons.is_empty(), "bundle.icon lists nothing");
    icons
}

fn icon_bytes(relative: &str) -> Vec<u8> {
    let path: PathBuf = app_crate().join(relative);
    std::fs::read(&path).unwrap_or_else(|error| {
        panic!("tauri.conf.json bundles {relative}, which is not there: {error}")
    })
}

#[test]
fn every_bundled_icon_is_the_format_its_name_claims() {
    for icon in configured_icons() {
        let bytes = icon_bytes(&icon);
        match Path::new(&icon).extension().and_then(|e| e.to_str()) {
            Some("png") => assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n", "{icon} is not a PNG"),
            // A real ICNS says so and carries its own length; a PNG renamed
            // to .icns does neither.
            Some("icns") => {
                assert_eq!(&bytes[..4], b"icns", "{icon} is not an ICNS container");
                let declared = u32::from_be_bytes(bytes[4..8].try_into().expect("length field"));
                assert_eq!(
                    declared as usize,
                    bytes.len(),
                    "{icon} declares a length it does not have"
                );
            }
            // Reserved 0, type 1 (icon), then the count of images.
            Some("ico") => {
                assert_eq!(&bytes[..4], &[0, 0, 1, 0], "{icon} is not an ICO container");
                let images = u16::from_le_bytes(bytes[4..6].try_into().expect("image count"));
                assert!(
                    images > 1,
                    "{icon} carries {images} image(s); Windows picks a size out of this file"
                );
            }
            other => panic!("{icon}: nothing here checks a {other:?} icon"),
        }
    }
}

/// `128x128@2x.png` is 256 pixels, and the bundler trusts the name.
#[test]
fn every_raster_icon_is_the_size_its_name_promises() {
    for icon in configured_icons() {
        let Some(expected) = size_from_name(&icon) else {
            continue;
        };
        let (width, height) = png_size(&icon_bytes(&icon));
        assert_eq!(
            (width, height),
            (expected, expected),
            "{icon} is {width}x{height}"
        );
    }
}

#[test]
fn every_raster_icon_is_drawn_in_the_kendex_lime() {
    for icon in configured_icons() {
        if size_from_name(&icon).is_none() {
            continue;
        }
        let share = lime_share(&png_drawn(&icon_bytes(&icon)));
        assert!(
            share > 0.10,
            "{icon} is {:.1}% lime; the mark covers about a fifth of the field",
            share * 100.0
        );
    }
}

/// The mark check on the standalone PNGs says nothing about what Windows
/// and macOS actually draw: those read the containers. A stale ICO or ICNS
/// alone would ship the old artwork with every other assertion green.
#[test]
fn the_images_inside_the_containers_carry_the_mark_too() {
    for icon in configured_icons() {
        let bytes = icon_bytes(&icon);
        let images = match Path::new(&icon).extension().and_then(|e| e.to_str()) {
            Some("ico") => ico_images(&bytes),
            Some("icns") => icns_images(&bytes),
            _ => continue,
        };
        assert!(
            !images.is_empty(),
            "{icon} carries no image this can read, so nothing checks what it draws"
        );
        for (label, image) in images {
            let share = lime_share(&image);
            assert!(
                share > 0.10,
                "{icon} {label} is {:.1}% lime; the mark covers about a fifth \
                 of the field",
                share * 100.0
            );
        }
    }
}

/// The four bytes that name an ICNS chunk type, the size in pixels that
/// name declares, and the mask it pairs with when it is not a PNG.
type ChunkType = (&'static [u8], u32, Option<&'static [u8]>);

/// Every chunk type the bundled ICNS carries. A chunk type is a size as
/// much as it is a picture — macOS reads `ic09` as 512 whatever is inside
/// it — so the artwork alone says nothing about whether it will draw right.
///
/// macOS takes 16x16 and 32x32 at 1x from Apple's own RGB encoding rather
/// than from a PNG, and this file holds none at either size, so on a display
/// that is not retina those two chunks are the whole small icon.
const ICNS_CHUNKS: [ChunkType; 10] = [
    (b"ic07", 128, None),
    (b"ic08", 256, None),
    (b"ic09", 512, None),
    (b"ic10", 1024, None), // 512@2x
    (b"ic11", 32, None),   // 16@2x
    (b"ic12", 64, None),   // 32@2x
    (b"ic13", 256, None),  // 128@2x
    (b"ic14", 512, None),  // 256@2x
    (b"is32", 16, Some(b"s8mk")),
    (b"il32", 32, Some(b"l8mk")),
];

/// The images inside a Windows ICO, labelled by the size its directory
/// claims. An entry that is not a PNG stops the test rather than being
/// skipped: a size nothing can read is a size nothing checks.
#[allow(clippy::expect_used)]
fn ico_images(bytes: &[u8]) -> Vec<(String, Vec<[u8; 3]>)> {
    let count = u16::from_le_bytes(bytes[4..6].try_into().expect("image count")) as usize;
    (0..count)
        .map(|index| {
            let entry = 6 + index * 16;
            let side = |byte: u8| if byte == 0 { 256 } else { u32::from(byte) };
            let (width, height) = (side(bytes[entry]), side(bytes[entry + 1]));
            let size =
                u32::from_le_bytes(bytes[entry + 8..entry + 12].try_into().expect("entry size"))
                    as usize;
            let offset = u32::from_le_bytes(
                bytes[entry + 12..entry + 16]
                    .try_into()
                    .expect("entry offset"),
            ) as usize;
            let image = &bytes[offset..offset + size];
            assert_eq!(
                &image[..8],
                b"\x89PNG\r\n\x1a\n",
                "the {width}x{height} entry is not a PNG, so nothing here reads it"
            );
            let (drawn_width, drawn_height) = png_size(image);
            assert_eq!(
                (drawn_width, drawn_height),
                (width, height),
                "the entry filed under {width}x{height} holds a \
                 {drawn_width}x{drawn_height} image"
            );
            (format!("{width}x{height}"), png_drawn(image))
        })
        .collect()
}

/// The images inside an ICNS, labelled by chunk type, each held to the
/// size its type declares. A chunk this knows nothing about stops the
/// test: the generator has started writing something nothing here reads.
fn icns_images(bytes: &[u8]) -> Vec<(String, Vec<[u8; 3]>)> {
    let chunks = icns_chunks(bytes);
    let mut images = Vec::new();
    for &(kind, body) in &chunks {
        let name = as_name(kind);
        let Some(&(_, side, pairs_with)) = ICNS_CHUNKS.iter().find(|(known, _, _)| *known == kind)
        else {
            assert!(
                ICNS_CHUNKS.iter().any(|(_, _, mask)| *mask == Some(kind)),
                "chunk {name} is not one this knows a size or an encoding for, \
                 so nothing checks what it draws"
            );
            continue;
        };
        let pixels = match pairs_with {
            // A PNG carries its own dimensions, and they have to be the ones
            // the chunk type promises: artwork filed under the wrong type is
            // a size macOS then scales or skips.
            None => {
                assert!(
                    body.starts_with(b"\x89PNG\r\n\x1a\n"),
                    "chunk {name} is not a PNG, so nothing here reads it"
                );
                let (width, height) = png_size(body);
                assert_eq!(
                    (width, height),
                    (side, side),
                    "chunk {name} draws {width}x{height}; macOS reads it as \
                     {side}x{side}"
                );
                png_drawn(body)
            }
            // The RGB pair carries no dimensions of its own, so the size the
            // type declares is what decodes it — a payload of another size
            // runs out of runs or leaves some over.
            Some(wanted) => {
                let mask = chunks
                    .iter()
                    .find(|(other, _)| *other == wanted)
                    .unwrap_or_else(|| panic!("{name} ships without its {} mask", as_name(wanted)))
                    .1;
                rgb_drawn(body, mask, side as usize)
            }
        };
        images.push((name, pixels));
    }
    for (kind, side, _) in ICNS_CHUNKS {
        assert!(
            chunks.iter().any(|(present, _)| *present == kind),
            "the icns carries no {} chunk, so macOS has nothing to draw at \
             {side}x{side}",
            as_name(kind)
        );
    }
    images
}

fn as_name(kind: &[u8]) -> String {
    String::from_utf8_lossy(kind).into_owned()
}

/// Every chunk in an ICNS, in the order the file lists them.
#[allow(clippy::expect_used)]
fn icns_chunks(bytes: &[u8]) -> Vec<(&[u8], &[u8])> {
    let mut chunks = Vec::new();
    let mut at = 8;
    while at + 8 <= bytes.len() {
        let kind = &bytes[at..at + 4];
        let length =
            u32::from_be_bytes(bytes[at + 4..at + 8].try_into().expect("chunk length")) as usize;
        assert!(
            length >= 8 && at + length <= bytes.len(),
            "chunk {} runs past the end of the file",
            as_name(kind)
        );
        chunks.push((kind, &bytes[at + 8..at + length]));
        at += length;
    }
    chunks
}

/// The drawn pixels of an RGB chunk, with its mask saying which count.
fn rgb_drawn(rgb: &[u8], mask: &[u8], side: usize) -> Vec<[u8; 3]> {
    let pixels = side * side;
    assert_eq!(
        mask.len(),
        pixels,
        "the mask holds {} bytes, not the {pixels} this size draws",
        mask.len()
    );
    let [red, green, blue] = rgb_planes(rgb, pixels);
    (0..pixels)
        .filter(|at| mask[*at] > 0)
        .map(|at| [red[at], green[at], blue[at]])
        .collect()
}

/// Apple's run-length encoding: the red, green and blue planes one after
/// another, each a stream of runs. A control byte below 0x80 introduces
/// that many literal bytes plus one; from 0x80 up it repeats the byte
/// that follows, three times plus the remainder. A chunk small enough to
/// hold the pixels outright skips the encoding.
#[allow(clippy::expect_used)]
fn rgb_planes(body: &[u8], pixels: usize) -> [Vec<u8>; 3] {
    if body.len() == pixels * 3 {
        let plane = |which: usize| body[which * pixels..(which + 1) * pixels].to_vec();
        return [plane(0), plane(1), plane(2)];
    }
    let mut planes = [Vec::new(), Vec::new(), Vec::new()];
    let mut at = 0;
    for plane in &mut planes {
        while plane.len() < pixels {
            let control = *body.get(at).expect("a run that starts inside the chunk");
            at += 1;
            if control < 0x80 {
                let run = usize::from(control) + 1;
                let literal = body
                    .get(at..at + run)
                    .expect("a run that ends inside the chunk");
                plane.extend_from_slice(literal);
                at += run;
            } else {
                let run = usize::from(control) - 0x80 + 3;
                let byte = *body.get(at).expect("a repeat that ends inside the chunk");
                at += 1;
                plane.extend(std::iter::repeat_n(byte, run));
            }
        }
        assert_eq!(plane.len(), pixels, "a colour plane overran its icon");
    }
    assert_eq!(at, body.len(), "the chunk carries runs past its last plane");
    planes
}

/// The size a bundled name promises, or `None` for a container.
fn size_from_name(icon: &str) -> Option<u32> {
    let name = Path::new(icon).file_stem()?.to_str()?;
    let (name, doubled) = match name.strip_suffix("@2x") {
        Some(base) => (base, 2),
        None => (name, 1),
    };
    let (width, _) = name.split_once('x')?;
    Some(width.parse::<u32>().ok()? * doubled)
}

#[allow(clippy::expect_used)]
fn png_size(bytes: &[u8]) -> (u32, u32) {
    let reader = png::Decoder::new(std::io::Cursor::new(bytes))
        .read_info()
        .expect("a readable PNG");
    let info = reader.info();
    (info.width, info.height)
}

/// The drawn pixels of a PNG: those its alpha channel does not hide.
#[allow(clippy::expect_used)]
fn png_drawn(bytes: &[u8]) -> Vec<[u8; 3]> {
    let mut reader = png::Decoder::new(std::io::Cursor::new(bytes))
        .read_info()
        .expect("a readable PNG");
    let mut pixels = vec![0; reader.output_buffer_size().expect("a bounded PNG")];
    let frame = reader.next_frame(&mut pixels).expect("a decodable PNG");
    let channels = frame.color_type.samples();
    assert!(
        channels >= 3 && frame.bit_depth == png::BitDepth::Eight,
        "expected 8-bit colour, got {:?} {:?}",
        frame.color_type,
        frame.bit_depth
    );
    pixels[..frame.buffer_size()]
        .chunks_exact(channels)
        .filter(|pixel| channels < 4 || pixel[3] > 0)
        .map(|pixel| [pixel[0], pixel[1], pixel[2]])
        .collect()
}

/// The share of drawn pixels within a shade of the mark's lime.
fn lime_share(drawn: &[[u8; 3]]) -> f64 {
    assert!(!drawn.is_empty(), "this image draws no pixel at all");
    let lime = drawn
        .iter()
        .filter(|pixel| {
            pixel
                .iter()
                .zip(LIME)
                .all(|(had, want)| had.abs_diff(want) <= 24)
        })
        .count();
    lime as f64 / drawn.len() as f64
}
