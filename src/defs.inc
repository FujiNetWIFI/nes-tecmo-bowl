; defs.inc -- equates shared by every netcode module.
;
; Three address spaces meet here: the game's own RAM and code (measured, not
; assumed: emu/profile.lua, spikes/NOTES.md), the FujiNet cartridge mailbox
; at $5000 (mirrored from fn-nes/pico/nes/firmware/include/fuji_mailbox.h),
; and the cart's WRAM at $6000 that the NES 2.0 header asks for (all netcode
; state lives there).

; ---------------------------------------------------------------- PPU / APU
PPU_CTRL        = $2000
PPU_MASK        = $2001
PPU_STATUS      = $2002
PPU_SCROLL      = $2005
PPU_ADDR        = $2006
PPU_DATA        = $2007

; ---------------------------------------------------------------- mailbox
; THE ONE RULE: only STA/STX/STY to $5500-$57FF, never an RMW instruction.
; tools/checkrom.py audits it.
FN_RPLY         = $5000         ; 1K reply window
FN_ACKS         = $5400         ; echoes SEQ when the reply is ready
FN_ERR          = $5402
FN_RCMD         = $5403         ; $06 ACK / $15 NAK
FN_RXLO         = $5404
FN_RXHI         = $5405
FN_MAG0         = $5409         ; 'F'
FN_MAG1         = $540A         ; 'N'
FN_RSEL         = $5500         ; STA $5500+n: register n = A
FN_TX           = $5700         ; a write anywhere appends to the TX stream
FR_DEV          = $00
FR_CMD          = $01
FR_NPAR         = $02
FR_DRST         = $05
FR_SEQ          = $10

FNDEV_FUJI      = $70
FNDEV_N1        = $71
NETCMD_OPEN     = $4F
NETCMD_CLOSE    = $43
NETCMD_READ     = $52
NETCMD_WRITE    = $57
NETCMD_STATUS   = $53
OPEN_MODE_RW    = 12
CMD_OPEN_APPKEY = $DC
CMD_CLOSE_APPKEY = $DB
CMD_READ_APPKEY = $DD

; Mailbox wait budgets, in ~0.55 s units (one unit = 256 x 256 polls).
MB_TMO_FAST     = 12            ; ordinary transaction: past the cart's 5 s
MB_TMO_OPEN     = 180           ; N: OPEN / CLOSE: the cart allows 90 s

; ---------------------------------------------------------------- wire
; Frame type ids -- must match server/tb_relay_server.py.
FT_HELLO        = $01
FT_LIST         = $02
FT_LOBBY        = $03
FT_JOIN         = $04
FT_START        = $05
FT_INPUT        = $06
FT_CRC          = $07
FT_STATE        = $08
FT_RESYNC       = $09
FT_BYE          = $0A
FT_PEER_LEFT    = $0B
FT_PING         = $0C
FT_PONG         = $0D
PROTO_VER       = 1

; ---------------------------------------------------------------- the game
; Tecmo Bowl runs its logic in eight cooperative tasks (slots of 16 bytes at
; $80-$F0: status, wait count, saved SP, bank, locals). The NMI does the
; display, the pad read, the RNG step, INC $03 and the wait-count wakeups.
G_TASKS         = $80           ; first slot; status $11 = waiting
G_CURTASK       = $00           ; slot running (or last run)
G_WOKEN         = $01           ; the wake loop's "highest woken" slot
G_FRAME         = $03           ; INC'd once per full NMI
G_PADRAW2       = $06           ; raw controller 2, as $C23D reads it
G_PADRAW1       = $07           ; raw controller 1
G_NMIARM        = $0A           ; bit 7 clear: the NMI is the $C064 stub
G_SAVEBANK      = $0C           ; the NMI's copy of $BFF8
G_HELD1         = $0D           ; P1 held / P2 held / P1 new / P2 new
G_HELD2         = $0E
G_NEW1          = $0F
G_NEW2          = $10
G_PPUCTRL       = $11           ; shadow of $2000 (nametable bits from $BF/$DF)
G_PPUMASK       = $12           ; shadow of $2001
G_RNG           = $1F           ; 24-bit additive RNG, $1F-$21
G_CHR1          = $2C           ; CHR1 bank the NMI selects every frame
G_CHR0REQ       = $CC           ; bit 7: CHR0 := bits 0-4 at the next NMI
G_ENGINE        = $E0           ; the object engine's task slot: 0 = no play
G_SCROLLX       = $DE           ; the NMI's $2005 pair
G_SCROLLY       = $BE
G_SCROLLXH      = $DF           ; bit 0 -> PPUCTRL bit 0 (X nametable)
G_SCROLLYH      = $BF           ; bit 0 -> PPUCTRL bit 1 (Y nametable)
G_BANKID        = $BFF8         ; every PRG bank names itself here
G_SPLIT         = $DD           ; task $D0: bit 7 no status-bar split; bit 6
                                ;   CHR1 below the split is $2D, else $10-$13
G_SPLITX        = $BA           ; task $D0: X scroll below the split
G_SPLITXH       = $BB           ; bit 0 -> PPUCTRL bit 0 below the split
G_CHR1SPLIT     = $2D

G_SCHED         = $C556         ; scheduler: SP = $FF, scan, dispatch
G_RESCAN        = $C559         ; the idle scan proper
G_SPAWN         = $C5EE         ; A = bank, X = slot
G_CTRLSW        = $C87E         ; MMC1 control, guarded by $0A
G_CHR0SW        = $C897         ; MMC1 CHR0
G_CHR1SW        = $C8B0         ; MMC1 CHR1
G_PRGSW         = $C8C9         ; MMC1 PRG, guarded by $0A
G_NMI_CHR0      = $C08B         ; NMI: apply $CC to CHR0 (A = $CC)
G_NMI_NOCHR0    = $C0A2         ; NMI: rendering off, then VRAM work
G_NMI_PAD       = $C203         ; NMI: the pad read after LDY #4 / LDA $0D
G_NMI_S0WAIT    = $C284         ; NMI: wait out the sprite-0 flag
G_NMI_WAKE      = $C500         ; NMI: wait counts, preemption
G_NMI_EXIT      = $C538         ; NMI: restore PRG from $0C, pull, RTI

NET_BANK        = 8             ; the netcode bank
FONT_BANK       = 11            ; 4K CHR bank holding the game's ASCII font

; ---------------------------------------------------------------- zero page
; $F4-$F8: never touched in the profile (title, menus, 2P play), and the NMI
; never touches them. Still borrowed, not owned: NET_IDLE saves them on the
; way in and puts them back on the way out (ZP_SAVE), so a game phase the
; profile missed loses nothing.
ZP_BASE         = $F4
ZP_LEN          = 5
ZP_PTR          = $F4           ; 2 bytes
ZP_PTR2         = $F6           ; 2 bytes
ZP_TMP          = $F8
