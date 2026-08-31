//! The icons `tauri.conf.json` bundles.
//!
//! Nothing else in this repo ever opens these files, so a stale one — or a
//! wrongly regenerated one — ships with every check green.
//!
//! Read back with the crates that write them: `tauri icon` builds the ICO
//! with `ico` and the ICNS with `tauri-icns`, and a container is only ever
//! as readable as what the bundler produced. A decoder of this suite's own
//! would be a second opinion about the format rather than a reading of the
//! file, and it was: three hundred lines of chunk walking, run-length
//! decoding and directory arithmetic, none of which the bundler consults.

use std::path::{Path, PathBuf};

use ico::{IconDir, IconImage};
use tauri_icns::{IconFamily, IconType, PixelFormat};

/// The mark's colour, the lime the kendex wordmark uses. The mark covers
/// about a fifth of a near-black field, so the share of this colour an
/// image carries says whether it is the mark, without pinning a pixel.
const LIME: [u8; 3] = [0xCC, 0xFF, 0x00];

/// Every icon type the bundled ICNS is expected to carry. A type is a size
/// as much as it is a picture — macOS reads `ic09` as 512 whatever is
/// inside it — so the artwork alone says nothing about whether it will draw
/// right, and the size each one promises is `IconType`'s answer rather than
/// a number written down again here.
///
/// macOS takes 16x16 and 32x32 at 1x from Apple's own RGB encoding rather
/// than from a PNG, and this file holds none at either size, so on a display
/// that is not retina those two types are the whole small icon.
const ICNS_TYPES: [IconType; 10] = [
    IconType::RGBA32_128x128,
    IconType::RGBA32_256x256,
    IconType::RGBA32_512x512,
    IconType::RGBA32_512x512_2x,
    IconType::RGBA32_16x16_2x,
    IconType::RGBA32_32x32_2x,
    IconType::RGBA32_128x128_2x,
    IconType::RGBA32_256x256_2x,
    IconType::RGB24_16x16,
    IconType::RGB24_32x32,
];

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
            // The reader macOS and Windows use is the reader here: a PNG
            // renamed to `.icns` is not a family, and one renamed to `.ico`
            // is not a directory.
            Some("png") => {
                png_image(&bytes);
            }
            Some("icns") => {
                let family = icns_family(&bytes);
                assert_eq!(
                    family.total_length() as usize,
                    bytes.len(),
                    "{icon} declares a length it does not have"
                );
            }
            Some("ico") => {
                let images = ico_dir(&bytes).entries().len();
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
        let image = png_image(&icon_bytes(&icon));
        assert_eq!(
            (image.width(), image.height()),
            (expected, expected),
            "{icon} is {}x{}",
            image.width(),
            image.height()
        );
    }
}

#[test]
fn every_raster_icon_is_drawn_in_the_kendex_lime() {
    for icon in configured_icons() {
        if size_from_name(&icon).is_none() {
            continue;
        }
        let share = lime_share(&drawn(&png_image(&icon_bytes(&icon))));
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

#[allow(clippy::expect_used)]
fn ico_dir(bytes: &[u8]) -> IconDir {
    IconDir::read(std::io::Cursor::new(bytes)).expect("a readable ICO container")
}

#[allow(clippy::expect_used)]
fn icns_family(bytes: &[u8]) -> IconFamily {
    IconFamily::read(std::io::Cursor::new(bytes)).expect("a readable ICNS container")
}

/// The images inside a Windows ICO, labelled by the size its directory
/// claims. The directory's size is what Windows picks by, so an entry whose
/// image is another size is a size nothing draws at.
#[allow(clippy::expect_used)]
fn ico_images(bytes: &[u8]) -> Vec<(String, Vec<[u8; 3]>)> {
    ico_dir(bytes)
        .entries()
        .iter()
        .map(|entry| {
            let (width, height) = (entry.width(), entry.height());
            let image = entry.decode().expect("a decodable ICO entry");
            assert_eq!(
                (image.width(), image.height()),
                (width, height),
                "the entry filed under {width}x{height} holds a {}x{} image",
                image.width(),
                image.height()
            );
            (format!("{width}x{height}"), drawn(&image))
        })
        .collect()
}

/// The images inside an ICNS, labelled by icon type, each held to the size
/// its type declares. The set is held to [`ICNS_TYPES`] in both directions:
/// a type missing is a size macOS has nothing to draw at, and one nobody
/// listed is artwork this says nothing about.
#[allow(clippy::expect_used)]
fn icns_images(bytes: &[u8]) -> Vec<(String, Vec<[u8; 3]>)> {
    let family = icns_family(bytes);
    let mut present = family.available_icons();
    present.sort_by_key(|icon| icon.ostype().to_string());
    let mut wanted = ICNS_TYPES.to_vec();
    wanted.sort_by_key(|icon| icon.ostype().to_string());
    assert_eq!(
        present, wanted,
        "the icns does not carry the icon types macOS is expected to draw from"
    );

    ICNS_TYPES
        .iter()
        .map(|&icon_type| {
            let image = family
                .get_icon_with_type(icon_type)
                .expect("a decodable ICNS icon")
                .convert_to(PixelFormat::RGBA);
            let side = (icon_type.pixel_width(), icon_type.pixel_height());
            assert_eq!(
                (image.width(), image.height()),
                side,
                "chunk {} draws {}x{}; macOS reads it as {}x{}",
                icon_type.ostype(),
                image.width(),
                image.height(),
                side.0,
                side.1
            );
            let pixels = image
                .data()
                .chunks_exact(4)
                .filter(|pixel| pixel[3] > 0)
                .map(|pixel| [pixel[0], pixel[1], pixel[2]])
                .collect();
            (icon_type.ostype().to_string(), pixels)
        })
        .collect()
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

/// A standalone PNG, decoded by the reader the ICO writer uses on one.
#[allow(clippy::expect_used)]
fn png_image(bytes: &[u8]) -> IconImage {
    IconImage::read_png(std::io::Cursor::new(bytes)).expect("a readable PNG")
}

/// The drawn pixels of an image: those its alpha channel does not hide.
fn drawn(image: &IconImage) -> Vec<[u8; 3]> {
    image
        .rgba_data()
        .chunks_exact(4)
        .filter(|pixel| pixel[3] > 0)
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
