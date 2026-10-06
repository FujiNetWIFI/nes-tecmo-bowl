; bank8.s -- the netcode. Tecmo Bowl is MMC1 with 8 x 16K PRG; the build
; grows it to 16 x 16K, moves the fixed bank to slot 15 and puts this file
; in slot 8 (the game only ever maps banks 0-6). The hooks that the NMI and
; the scheduler reach are in fix.s, in the fixed bank's free space; this
; bank is mapped only by them, through the game's own guarded PRG switch.
;
; How control gets here (all patch sites: tools/patches.py):
;   RESET  $FFFC        -> W_RESET   (the game's stub, moved for "FUJI")
;   init   $C044  JSR $C5EE -> JSR W_BOOT  -> NET_BOOT, then the spawn
;   NMI    $C064  busy exit -> JMP W_STUB  (counts frames)
;          $C087  LDA $CC   -> JMP W_DISP  (tick NMI or lag NMI)
;          $C1FF  pad read  -> JMP W_SIM   (net: no pads, RNG, $03)
;          $C28D  JMP $C500 -> JMP W_WAKE  (net: no wakeups)
;   sched  $C569  idle scan -> JMP W_IDLE  -> NET_IDLE (lockstep.s)
;   MMC1   $C87E, $C897     -> W_CTRL, W_CHR0 (shadows for resync)
;
; Build kinds (ca65 -D BUILD_KIND=n):
;   0 HOOK   every hook installed, nothing armed: must play exactly as stock
;   1 NET    the real thing: session, lobby, lockstep
;   2 SOLO   lockstep with no network: the "remote" side is controller 2
;            (or fuzz), delayed like a peer's input -- run-lag and det
; Test switches: FUZZ (inputs from per-side streams), STALL_N (a stall of
; N frames every 64 ticks), JITTER (hold every tick's tasks back a varying
; part of a frame), TRACE (per-tick checksum ring), AUTO_JOIN (rig consoles
; challenge the first idle lobby entry), SOLO_DELAY (the d of a SOLO build).

        .include "defs.inc"

.ifndef BUILD_KIND
BUILD_KIND = 1
.endif
.ifndef FUZZ
FUZZ = 0
.endif
.ifndef STALL_N
STALL_N = 0
.endif
.ifndef JITTER
JITTER = 0
.endif
.ifndef TRACE
TRACE = 0
.endif
.ifndef AUTO_JOIN
AUTO_JOIN = 0
.endif
.ifndef SOLO_DELAY
SOLO_DELAY = 3
.endif

        .include "netcode/image.inc"
        .include "vars.inc"

; ---------------------------------------------------------------- bank head
        .segment "B8HEAD"
        ; Tecmo Bowl names its banks at $BFF8, not here; the build stamps
        ; this bank's tail ($BFE0-$BFFF: reset stub, ID 8, vectors).
        .byte   "TECMO BOWL NETPLAY", 0

; ---------------------------------------------------------------- boot
        .segment "CODE"

; NET_BOOT -- from W_BOOT, after the game's RAM clear, NMI still off.
.proc NET_BOOT
        ; WRAM survives a console reset, and a game booted from the Lobby
        ; inherits whatever the Lobby left there: all of it goes, except the
        ; mirroring the game has already set ($C035, through W_CTRL)
        lda     CTRL_SH
        pha
        lda     #$00
        sta     ZP_PTR
        lda     #$60
        sta     ZP_PTR+1
        lda     #0
        tay
        ldx     #$20
:       sta     (ZP_PTR),y
        iny
        bne     :-
        inc     ZP_PTR+1
        dex
        bne     :-
        pla
        sta     CTRL_SH

.if ::BUILD_KIND = 1
        jsr     SES_MAIN        ; sets NET_MODE: 1 netplay, 0 local game
.elseif ::BUILD_KIND = 2
        jsr     LS_SOLO_INIT
        lda     #2
        sta     NET_MODE
.endif
        ; hand the machine back as the game left it at $C044: NMI and
        ; rendering off, nothing of ours on screen, our zero page bytes
        ; back to the zero its RAM clear gave them
        jsr     UI_OFF
        jsr     UI_WIPE
        lda     #0
        ldx     #ZP_LEN-1
:       sta     ZP_BASE,x
        dex
        bpl     :-
        rts
.endproc

        .include "fix.s"
        .segment "CODE"
        .include "ui/text.s"
        .include "netcode/mailbox.s"
        .include "netcode/session.s"
        .include "netcode/lockstep.s"
        .include "netcode/resync.s"
