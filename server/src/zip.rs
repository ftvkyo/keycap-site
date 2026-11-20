// SPDX-License-Identifier: MPL-2.0

//! Zip archives written as their entries come, each stored as it is, as
//! PNG is compressed already, or deflated, as 3MF's XML wants.

use std::io::{self, Write};

use flate2::Compression;
use flate2::write::DeflateEncoder;

/// 1980-01-01, the earliest date zip has, so that an archive's bytes
/// depend only on what it holds
const DOS_DATE: u16 = (1 << 5) | 1;

/// Names are UTF-8
const FLAGS: u16 = 1 << 11;

/// Version 2.0, the first with directories and deflate, the most the
/// entries need
const VERSION: u16 = 20;

const STORED: u16 = 0;
const DEFLATED: u16 = 8;

pub struct Zip<W: Write> {
    out: W,
    /// Where the next entry starts
    offset: u64,
    entries: Vec<Entry>,
}

struct Entry {
    name: String,
    method: u16,
    crc: u32,
    /// Its size in the archive
    packed: u32,
    size: u32,
    offset: u32,
}

impl<W: Write> Zip<W> {
    pub fn new(out: W) -> Self {
        Zip {
            out,
            offset: 0,
            entries: vec![],
        }
    }

    pub fn add(&mut self, name: &str, data: &[u8]) -> io::Result<()> {
        self.put(name, data, STORED, data)
    }

    pub fn add_deflated(&mut self, name: &str, data: &[u8]) -> io::Result<()> {
        let mut encoder = DeflateEncoder::new(vec![], Compression::default());
        encoder.write_all(data)?;
        self.put(name, data, DEFLATED, &encoder.finish()?)
    }

    /// Writes the entry `name` of `data`, as `packed` by `method`.
    fn put(&mut self, name: &str, data: &[u8], method: u16, packed: &[u8]) -> io::Result<()> {
        let entry = Entry {
            name: name.to_owned(),
            method,
            crc: crc32fast::hash(data),
            packed: small(packed.len() as u64)?,
            size: small(data.len() as u64)?,
            offset: small(self.offset)?,
        };
        let mut header = vec![];
        header.extend(0x04034b50_u32.to_le_bytes());
        header.extend(VERSION.to_le_bytes());
        entry.common(&mut header)?;
        // No extra field
        header.extend(0_u16.to_le_bytes());
        header.extend(name.as_bytes());
        self.out.write_all(&header)?;
        self.out.write_all(packed)?;
        self.offset += (header.len() + packed.len()) as u64;
        self.entries.push(entry);
        Ok(())
    }

    /// Writes the central directory, and returns the writer.
    pub fn finish(mut self) -> io::Result<W> {
        let start = small(self.offset)?;
        let mut directory = vec![];
        for entry in &self.entries {
            directory.extend(0x02014b50_u32.to_le_bytes());
            // Made by and needing the same version
            directory.extend(VERSION.to_le_bytes());
            directory.extend(VERSION.to_le_bytes());
            entry.common(&mut directory)?;
            // No extra field, comment, disk, or attributes
            directory.extend([0; 12]);
            directory.extend(entry.offset.to_le_bytes());
            directory.extend(entry.name.as_bytes());
        }
        let count = u16::try_from(self.entries.len())
            .map_err(|_| io::Error::other("a zip without ZIP64 holds at most 65535 files"))?;
        let size = small(directory.len() as u64)?;
        small(u64::from(start) + u64::from(size))?;
        directory.extend(0x06054b50_u32.to_le_bytes());
        // This disk, and the one the directory starts on
        directory.extend([0; 4]);
        directory.extend(count.to_le_bytes());
        directory.extend(count.to_le_bytes());
        directory.extend(size.to_le_bytes());
        directory.extend(start.to_le_bytes());
        // No comment
        directory.extend([0; 2]);
        self.out.write_all(&directory)?;
        Ok(self.out)
    }
}

impl Entry {
    /// The fields local and central headers share, from the flags to the
    /// name's length.
    fn common(&self, header: &mut Vec<u8>) -> io::Result<()> {
        let name = u16::try_from(self.name.len())
            .map_err(|_| io::Error::other(format!("the name {} is too long", self.name)))?;
        header.extend(FLAGS.to_le_bytes());
        header.extend(self.method.to_le_bytes());
        // Midnight
        header.extend(0_u16.to_le_bytes());
        header.extend(DOS_DATE.to_le_bytes());
        header.extend(self.crc.to_le_bytes());
        header.extend(self.packed.to_le_bytes());
        header.extend(self.size.to_le_bytes());
        header.extend(name.to_le_bytes());
        Ok(())
    }
}

/// `n` as zip's 32-bit sizes and offsets have it.
fn small(n: u64) -> io::Result<u32> {
    u32::try_from(n).map_err(|_| io::Error::other("a zip without ZIP64 holds at most 4 GiB"))
}

#[cfg(test)]
mod test {
    use std::io::Read;

    use flate2::read::DeflateDecoder;

    use super::Zip;

    /// The archive's entries, as (name, data), read from its central
    /// directory as unzip reads them.
    fn entries(archive: &[u8]) -> Vec<(String, Vec<u8>)> {
        let u16_at = |i: usize| u16::from_le_bytes([archive[i], archive[i + 1]]) as usize;
        let u32_at = |i: usize| u32::from_le_bytes(archive[i..i + 4].try_into().unwrap()) as usize;
        let end = archive.len() - 22;
        assert_eq!(u32_at(end), 0x06054b50);
        let (count, mut at) = (u16_at(end + 10), u32_at(end + 16));
        (0..count)
            .map(|_| {
                assert_eq!(u32_at(at), 0x02014b50);
                let (method, crc, packed) = (u16_at(at + 10), u32_at(at + 16), u32_at(at + 20));
                let (size, name) = (u32_at(at + 24), u16_at(at + 28));
                let local = u32_at(at + 42);
                let named = String::from_utf8(archive[at + 46..at + 46 + name].to_vec()).unwrap();
                at += 46 + name;
                assert_eq!(u32_at(local), 0x04034b50);
                let start = local + 30 + u16_at(local + 26);
                let mut data = archive[start..start + packed].to_vec();
                if method == 8 {
                    let mut inflated = vec![];
                    DeflateDecoder::new(&data[..])
                        .read_to_end(&mut inflated)
                        .unwrap();
                    data = inflated;
                }
                assert_eq!(data.len(), size);
                assert_eq!(crc32fast::hash(&data) as usize, crc);
                (named, data)
            })
            .collect()
    }

    #[test]
    fn entries_read_back() {
        let mut zip = Zip::new(vec![]);
        zip.add("config.ini", b"action = print\n").unwrap();
        zip.add("part00000.png", &[0, 1, 2, 255]).unwrap();
        zip.add("empty", b"").unwrap();
        let long = "layer ".repeat(1000);
        zip.add_deflated("3D/3dmodel.model", long.as_bytes())
            .unwrap();
        let archive = zip.finish().unwrap();
        assert!(archive.len() < long.len() / 2);
        assert_eq!(
            entries(&archive),
            [
                ("config.ini".to_owned(), b"action = print\n".to_vec()),
                ("part00000.png".to_owned(), vec![0, 1, 2, 255]),
                ("empty".to_owned(), vec![]),
                ("3D/3dmodel.model".to_owned(), long.into_bytes()),
            ]
        );
    }
}
