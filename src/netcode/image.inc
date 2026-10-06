; image.inc -- the resync state image (see resync.s).
;
;   0    .. 255     $0000-$00FF  zero page (applied minus the skip list)
;   256  .. 511     $0100-$01FF  stack page: the eight task stacks hold live
;                                context (applied minus $01E5-$01FF, the
;                                scheduler's own stack, where we are)
;   512  .. 2047    $0200-$07FF  OAM page, objects, VRAM lists, sound
;   2048 .. 4095    the two physical nametables: PPU $2000, then $2400
;                   (vertical mirroring) or $2800 (horizontal), per CTRL_SH
;   4096 .. 4127    PPU $3F00-$3F1F  palette
;   4128            CTRL_SH (MMC1 control: mirroring)
;   4129            CHR0_SH (MMC1 CHR0; CHR1 is rewritten every NMI)

IMG_STACK       = 256
IMG_RAM2        = 512
IMG_VRAM        = 2048
IMG_PAL         = 4096
IMG_CTRL        = 4128
IMG_CHR0        = 4129
IMG_TOTAL       = 4130
RS_CHUNK        = 96            ; data bytes per STATE frame (len = n + 3)
