//! The icons `tauri.conf.json` bundles.
//!
//! Nothing else in this repo ever opens these files, so a stale one — or a
//! wrongly regenerated one — ships with every check green. That is not
//! hypothetical: an `icon.icns` generated with ImageMagick came out a PNG
//! wearing an `.icns` extension, and only `file(1)` said so.

use std::path::{Path, PathBuf};

/// The mark's colour, the lime the kendex wordmark uses. The chevron this
/// icon replaced was white on a near-black field, so how much of this
/// colour an icon carries tells the two apart without pinning a pixel.
const LIME: [u8; 3] = [0xCC, 0xFF, 0x00];

fn app_crate() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

/// The bundled set, read from the config rather than listed here: an icon
/// added to the bundle and never generated is exactly the gap this closes.
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
        let share = lime_share(&icon_bytes(&icon));
        assert!(
            share > 0.10,
            "{icon} is {:.1}% lime; the mark covers about a fifth of the field, \
             and the chevron it replaced was none of it",
            share * 100.0
        );
    }
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

fn png_size(bytes: &[u8]) -> (u32, u32) {
    let reader = png::Decoder::new(std::io::Cursor::new(bytes))
        .read_info()
        .expect("a readable PNG");
    let info = reader.info();
    (info.width, info.height)
}

/// The share of drawn pixels within a shade of the mark's lime.
fn lime_share(bytes: &[u8]) -> f64 {
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

    let drawn: Vec<&[u8]> = pixels[..frame.buffer_size()]
        .chunks_exact(channels)
        .filter(|pixel| channels < 4 || pixel[3] > 0)
        .collect();
    let lime = drawn
        .iter()
        .filter(|pixel| {
            pixel[..3]
                .iter()
                .zip(LIME)
                .all(|(had, want)| had.abs_diff(want) <= 24)
        })
        .count();
    lime as f64 / drawn.len() as f64
}
