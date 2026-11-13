#!/usr/bin/env python3
"""Generate pinned unicode-width and unicode-segmentation properties."""

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

SHA256 = "54753db78d67856fd202b4b072772c8c8a3f3297332a4f7bd77c84966946ea79"
SEGMENTATION_SHA256 = "e229fbbc93599c5df42c174bdf77602ced0789e1e1c73f7b979a725a56c92da1"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tables", type=Path)
    parser.add_argument("segmentation", type=Path)
    args = parser.parse_args()
    tables = args.tables.resolve()
    assert hashlib.sha256(tables.read_bytes()).hexdigest() == SHA256
    segmentation = args.segmentation.resolve()
    assert hashlib.sha256(segmentation.read_bytes()).hexdigest() == SEGMENTATION_SHA256
    version = subprocess.check_output(["rustc", "--version"], text=True)
    if not version.startswith("rustc 1.99.0 "):
        raise RuntimeError("Regeneration requires the reference Rust 1.99.0 toolchain")
    source = r"""
include!(TABLES);
#[path = SEGMENTATION]
mod segmentation;
use std::io::Write;
fn value(cp: u32) -> (u8, u16, u8, u8) {
    if let Some(c) = char::from_u32(cp) {
        let (width, info) = lookup_width(c);
        let bits = starts_emoji_presentation_seq(c) as u8
            | (starts_non_ideographic_text_presentation_seq(c) as u8) << 1
            | (is_emoji_modifier_base(c) as u8) << 2
            | (is_transparent_zero_width(c) as u8) << 3
            | (is_ligature_transparent(c) as u8) << 4
            | (c.is_uppercase() as u8) << 5;
        let grapheme = segmentation::grapheme::grapheme_category(c).2 as u8
            | (segmentation::derived_property::InCB_Extend(c) as u8) << 4
            | (segmentation::is_incb_linker(c) as u8) << 5;
        (width, info.0, bits, grapheme)
    } else { (1, 0, 0, 0) }
}
fn emit(out: &mut Vec<u8>, start: u32, end: u32, v: (u8, u16, u8, u8)) {
    out.extend(start.to_le_bytes());
    out.extend(end.to_le_bytes());
    out.push(v.0);
    out.extend(v.1.to_le_bytes());
    out.push(v.2);
    out.push(v.3);
}
fn main() {
    let mut out = Vec::new();
    let mut start = 0;
    let mut previous = value(0);
    for cp in 1..=0x10ffff {
        let current = value(cp);
        if current != previous {
            emit(&mut out, start, cp - 1, previous);
            start = cp;
            previous = current;
        }
    }
    emit(&mut out, start, 0x10ffff, previous);
    std::io::stdout().write_all(&out).unwrap();
}
"""
    source = source.replace("TABLES", '"' + str(tables) + '"')
    source = source.replace("SEGMENTATION", '"' + str(segmentation) + '"')
    with tempfile.TemporaryDirectory(prefix="tms-width-") as directory:
        root = Path(directory)
        (root / "generate.rs").write_text(source)
        subprocess.run(
            [
                "rustc",
                "--edition=2021",
                "-O",
                str(root / "generate.rs"),
                "-o",
                str(root / "generate"),
            ],
            check=True,
        )
        output = subprocess.check_output([str(root / "generate")])
    assert len(output) % 13 == 0
    Path(__file__).with_name("width-data.bin").write_bytes(output)


if __name__ == "__main__":
    main()
