# rom/

Put your own dump of Tecmo Bowl (USA) here as `tecmo_bowl.nes`. It is not in
this repository and must never be committed (`.gitignore` excludes every
`.nes` file).

Expected image:

| | |
|---|---|
| Header | NES 2.0, mapper 1 (MMC1), 128K PRG, 128K CHR-ROM, no PRG-RAM |
| File SHA-1 | `22faa1b3cf5cdddfacfbe1a67ebcb91b586d06f8` |
| PRG CRC32 | `4F0C69BE` |
| CHR CRC32 | `2FA4B7BE` |

`tools/build_rom.py` checks the bytes at every patch site and refuses any
other image; `tools/mkfontmap.py` checks the font glyphs the text screens
borrow from its CHR.
