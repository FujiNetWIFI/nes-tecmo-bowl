; resync.s -- desync detection and recovery.
;
; Both consoles checksum their sim state every 64 ticks (LS_CKSUM) and send
; it; the relay forwards it to the peer. Each compares the peer's CRC with
; its own record for the same tick. On a mismatch:
;   guest: sends RESYNC once and keeps playing
;   host:  waits for a quiet moment (RS_QUIET, capped at RS_PEND_MAX ticks),
;          then snapshots the whole state image (image.inc) into WRAM and
;          pushes it: BEGIN(R), chunks, END. Both sides then re-baseline:
;          tick := R, input rings idle, watermark R+d-1.
; The guest freezes on BEGIN (LS_HOLD, inside LS_TICK) and applies the image
; atomically on END. Stale INPUT frames from before the push carry ticks
; below the new watermark and are dropped (R is 16 ticks out for that).
;
; Both ends touch the world at the same point of a tick: inside LS_TICK,
; after the tick NMI's display pass. An END that arrives while NET_IDLE is
; pumping between ticks waits (RS_ENDP) for the next LS_TICK, or that tick
; NMI would replay a VRAM request the host's image already has done.
;
; STATE frame: [len][08][pos_lo][pos_hi][data...]; pos_hi = $FF marks a
; control frame: pos_lo 0 = BEGIN (payload R_lo, R_hi), 1 = END.

RS_PEND_MAX     = 240           ; ticks (4 s) to wait for a quiet moment

; RS_CLR_CRC -- invalidate every record. NOT zero: a zeroed record reads as
; a real one for tick 0 with CRC 0. A tick_lo of $FF never occurs in a
; record (they are all on 64-tick boundaries).
.proc RS_CLR_CRC
        lda     #$FF
        ldx     #31
:       sta     OWN_CRC,x
        dex
        bpl     :-
        rts
.endproc

; RS_SLOT -- X = record offset for tick (A = lo, Y = hi): ((tick >> 6) & 7) * 4
.proc RS_SLOT
        sta     ZP_T1
        tya
        and     #1
        asl     a
        asl     a
        sta     ZP_T2           ; hi bit 0 -> slot bit 2
        lda     ZP_T1
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a               ; lo bits 7-6 -> slot bits 1-0
        ora     ZP_T2
        asl     a
        asl     a
        tax
        rts
.endproc

; RS_RECORD_CRC -- keep our (tick, CRC) for the peer's report.
.proc RS_RECORD_CRC
        lda     TICK_LO
        ldy     TICK_HI
        jsr     RS_SLOT
        lda     TICK_LO
        sta     OWN_CRC,x
        lda     TICK_HI
        sta     OWN_CRC+1,x
        lda     CRC_LO
        sta     OWN_CRC+2,x
        lda     CRC_HI
        sta     OWN_CRC+3,x
        rts
.endproc

; RS_ON_CRC -- the peer's CRC: FRMBUF+2/3 tick, +4/5 crc.
.proc RS_ON_CRC
        lda     NET_ACTIVE
        beq     @out
        lda     RESYNC_HOLD
        ora     RS_PEND
        bne     @out            ; already recovering
        lda     FRMBUF+2
        ldy     FRMBUF+3
        jsr     RS_SLOT
        lda     OWN_CRC,x
        cmp     FRMBUF+2
        bne     @out            ; no record for that tick (yet, or any more)
        lda     OWN_CRC+1,x
        cmp     FRMBUF+3
        bne     @out
        lda     OWN_CRC+2,x
        cmp     FRMBUF+4
        bne     @bad
        lda     OWN_CRC+3,x
        cmp     FRMBUF+5
        beq     @out            ; agreed
@bad:   ; wanted, but not acted on here: RS_PENDING waits for a quiet moment.
        ; The guest keeps playing until BEGIN arrives -- freezing now would
        ; sit through the very play we are waiting to finish.
        lda     CRC_MIS
        cmp     #$FF
        beq     :+
        inc     CRC_MIS
:       lda     #1
        sta     RS_PEND
        lda     #0
        sta     RS_PTMO
        lda     NET_ROLE
        beq     @out            ; host: RS_PENDING drives the push
        lda     #3              ; guest: ask once
        sta     TXBUF
        lda     #FT_RESYNC
        sta     TXBUF+1
        lda     FRMBUF+2
        sta     TXBUF+2
        lda     FRMBUF+3
        sta     TXBUF+3
        ldx     #4
        jmp     NET_WRITE
@out:   rts
.endproc

; RS_ON_REQ -- the guest asked for a push (host only, once).
.proc RS_ON_REQ
        lda     NET_ROLE
        bne     @out
        lda     RESYNC_HOLD
        ora     RS_PEND
        bne     @out
        lda     #1
        sta     RS_PEND
        lda     #0
        sta     RS_PTMO
@out:   rts
.endproc

; RS_PENDING -- host, once per tick (after T++): push when quiet or capped.
.proc RS_PENDING
        lda     RS_PEND
        beq     @out
        lda     NET_ROLE
        ora     RESYNC_HOLD
        bne     @out
        lda     RS_PTMO
        cmp     #$FF
        beq     :+
        inc     RS_PTMO
:       jsr     RS_QUIET
        beq     @tmo
        lda     #1              ; quiet: the swap should be invisible
        bne     @go
@tmo:   lda     RS_PTMO
        cmp     #RS_PEND_MAX
        bcc     @out
        lda     #2              ; gave up waiting: pushing mid-play
@go:    sta     RS_GATE
        lda     RS_PTMO
        sta     RS_WAITED
        jmp     RS_PUSH
@out:   rts
.endproc

; RS_QUIET -- Z clear if now is a good moment to replace the world: any
; time the ball is not live. The object engine runs in task slot $E0 during
; a play and its slot is free (status 0) on the play-select screen, between
; plays and in the menus (emu/modes.lua).
.proc RS_QUIET
        lda     G_ENGINE
        beq     @yes
        lda     #0
        rts
@yes:   lda     #1
        rts
.endproc

; ---------------------------------------------------------------------------
; RS_PUSH -- host: snapshot, BEGIN(R), chunks, END, re-baseline. Runs to
; completion inside LS_POST, with the scheduler idle: the sim cannot move
; underneath it.
.proc RS_PUSH
        jsr     RS_ENTER_HOLD
        lda     TICK_LO
        clc
        adc     #16
        sta     RS_R_LO
        lda     TICK_HI
        adc     #0
        sta     RS_R_HI
        jsr     RS_SNAPSHOT
        ; BEGIN
        lda     #5
        sta     TXBUF
        lda     #FT_STATE
        sta     TXBUF+1
        lda     #0
        sta     TXBUF+2
        lda     #$FF
        sta     TXBUF+3
        lda     RS_R_LO
        sta     TXBUF+4
        lda     RS_R_HI
        sta     TXBUF+5
        ldx     #6
        jsr     NET_WRITE
        ; chunks
        lda     #0
        sta     RS_POS_LO
        sta     RS_POS_HI
@chunk: lda     #<IMG_TOTAL     ; remaining = total - pos
        sec
        sbc     RS_POS_LO
        sta     ZP_T1
        lda     #>IMG_TOTAL
        sbc     RS_POS_HI
        bne     @full
        lda     ZP_T1
        beq     @end
        cmp     #RS_CHUNK
        bcc     @n
@full:  lda     #RS_CHUNK
@n:     sta     RS_N
        clc
        adc     #3
        sta     TXBUF
        lda     #FT_STATE
        sta     TXBUF+1
        lda     RS_POS_LO
        sta     TXBUF+2
        lda     RS_POS_HI
        sta     TXBUF+3
        lda     #<IMG_BUF
        clc
        adc     RS_POS_LO
        sta     ZP_PTR
        lda     #>IMG_BUF
        adc     RS_POS_HI
        sta     ZP_PTR+1
        ldy     #0
:       lda     (ZP_PTR),y
        sta     TXBUF+4,y
        iny
        cpy     RS_N
        bne     :-
        lda     RS_N
        clc
        adc     #4
        tax
        jsr     NET_WRITE
        lda     RS_POS_LO
        clc
        adc     RS_N
        sta     RS_POS_LO
        bcc     @chunk
        inc     RS_POS_HI
        jmp     @chunk
@end:   lda     #3
        sta     TXBUF
        lda     #FT_STATE
        sta     TXBUF+1
        lda     #1
        sta     TXBUF+2
        lda     #$FF
        sta     TXBUF+3
        ldx     #4
        jsr     NET_WRITE
        jmp     RS_REBASE
.endproc

; ---------------------------------------------------------------------------
; RS_ON_STATE -- guest: a STATE frame in FRMBUF.
.proc RS_ON_STATE
        lda     NET_ACTIVE
        bne     :+
        rts
:
        lda     FRMBUF+3
        cmp     #$FF
        beq     @ctl
        ; Data is only legitimate inside a hold a BEGIN opened. Outside one
        ; a "STATE" frame is a misparse, and its position would aim a write
        ; anywhere.
        lda     RESYNC_HOLD
        beq     @bad
        lda     FRMBUF
        sec
        sbc     #3
        beq     @bad
        bcc     @bad
        sta     RS_N
        ; bounds: pos + n <= IMG_TOTAL
        lda     FRMBUF+2
        clc
        adc     RS_N
        sta     ZP_T1
        lda     FRMBUF+3
        adc     #0
        cmp     #>IMG_TOTAL
        bcc     @inb
        bne     @bad
        lda     ZP_T1
        cmp     #<IMG_TOTAL+1
        bcs     @bad
@inb:   lda     #<IMG_BUF
        clc
        adc     FRMBUF+2
        sta     ZP_PTR
        lda     #>IMG_BUF
        adc     FRMBUF+3
        sta     ZP_PTR+1
        ldy     #0
:       lda     FRMBUF+4,y
        sta     (ZP_PTR),y
        iny
        cpy     RS_N
        bne     :-
        rts
@ctl:   lda     FRMBUF+2
        bne     @endf
        lda     FRMBUF
        cmp     #5
        bcc     @bad
        jsr     RS_ENTER_HOLD   ; BEGIN
        lda     FRMBUF+4
        sta     RS_R_LO
        lda     FRMBUF+5
        sta     RS_R_HI
        rts
@endf:  cmp     #1
        bne     @out
        lda     RESYNC_HOLD
        beq     @out            ; no hold open: not our END
        lda     IN_TICK
        bne     :+
        lda     #1              ; between ticks: LS_HOLD applies it
        sta     RS_ENDP
        rts
:       jsr     RS_APPLY
        jmp     RS_REBASE
@bad:   lda     DIAG_REJ        ; a misframed stream got this far
        cmp     #$FF
        beq     @out
        inc     DIAG_REJ
@out:   rts
.endproc

; ---------------------------------------------------------------------------
.proc RS_ENTER_HOLD
        lda     #1
        sta     RESYNC_HOLD
        lda     #0
        sta     RS_ENDP
        sta     RS_TO_LO
        sta     RS_TO_HI
        jmp     RS_CLR_CRC
.endproc

.proc RS_REBASE
        lda     HUD_RSY
        cmp     #$FF
        beq     :+
        inc     HUD_RSY
:       lda     #0
        sta     RS_PEND
        sta     RS_PTMO
        tax
:       sta     LOC_RING,x      ; every input ring back to idle
        sta     RMT_RING,x
        inx
        bne     :-
        lda     RS_R_LO
        sta     TICK_LO
        lda     RS_R_HI
        sta     TICK_HI
        ; watermark = R + d - 1
        lda     RS_R_LO
        clc
        adc     NET_DELAY
        sta     ZP_T1
        lda     RS_R_HI
        adc     #0
        sta     ZP_T2
        lda     ZP_T1
        sec
        sbc     #1
        sta     RMT_WM_LO
        lda     ZP_T2
        sbc     #0
        sta     RMT_WM_HI
        jsr     RS_CLR_CRC
        lda     #$FF            ; a CRC folded across the rebase is void
        sta     CK_NEXT
        lda     #0
        sta     RESYNC_HOLD
        sta     LS_WAITC_LO
        sta     LS_WAITC_HI
        rts
.endproc


; ---------------------------------------------------------------------------
; RS_SNAPSHOT -- the image into IMG_BUF (host).
.proc RS_SNAPSHOT
        ldx     #0
:       lda     $00,x
        sta     IMG_BUF,x
        lda     $0100,x
        sta     IMG_BUF+IMG_STACK,x
        inx
        bne     :-
        ldx     #ZP_LEN-1       ; borrowed: the game's values are in ZP_SAVE
:       lda     ZP_SAVE,x
        sta     IMG_BUF+ZP_BASE,x
        dex
        bpl     :-
        jsr     rs_ram2_ptrs
@r2:    ldy     #0
:       lda     (ZP_PTR2),y
        sta     (ZP_PTR),y
        iny
        bne     :-
        inc     ZP_PTR+1
        inc     ZP_PTR2+1
        dex
        bne     @r2
        lda     CTRL_SH
        sta     IMG_BUF+IMG_CTRL
        lda     CHR0_SH
        sta     IMG_BUF+IMG_CHR0
        ; PPU: NMI off (a lag NMI would scribble the address latch), screen
        ; off, +1 increments
        jsr     rs_ppu_off
        jsr     rs_vram_ptr
        lda     #$20
        jsr     rs_nt_read
        jsr     rs_nt2
        jsr     rs_nt_read
        lda     #$3F            ; palette reads are not buffered
        sta     PPU_ADDR
        lda     #$00
        sta     PPU_ADDR
        ldx     #0
:       lda     PPU_DATA
        and     #$3F            ; the open-bus top bits are not palette
        sta     IMG_BUF+IMG_PAL,x
        inx
        cpx     #32
        bne     :-
        jmp     rs_ppu_on
.endproc

; RS_APPLY -- IMG_BUF into the machine (guest), at END, inside LS_TICK.
.proc RS_APPLY
        ; zero page, minus $0A (the NMI arm flag: ours is the live one) and
        ; $0C (the NMI's own bank save). The borrowed $F4-$F8 go to ZP_SAVE,
        ; which NET_IDLE puts back when the tick ends.
        ldx     #0
@zp:    cpx     #G_NMIARM
        beq     @skip
        cpx     #G_SAVEBANK
        beq     @skip
        cpx     #ZP_BASE
        bcc     @take
        cpx     #ZP_BASE+ZP_LEN
        bcs     @take
        lda     IMG_BUF,x
        sta     ZP_SAVE-ZP_BASE,x
        jmp     @skip
@take:  lda     IMG_BUF,x
        sta     $00,x
@skip:  inx
        bne     @zp
        ; the task stacks; $01E5-$01FF is the scheduler's stack, and ours
        ldx     #0
:       lda     IMG_BUF+IMG_STACK,x
        sta     $0100,x
        inx
        cpx     #$E5
        bne     :-
        jsr     rs_ram2_ptrs
@r2:    ldy     #0
:       lda     (ZP_PTR),y
        sta     (ZP_PTR2),y
        iny
        bne     :-
        inc     ZP_PTR+1
        inc     ZP_PTR2+1
        dex
        bne     @r2
        jsr     rs_ppu_off
        ; the mapper: mirroring first (it decides where nametable 2 is),
        ; CHR0; CHR1 the next NMI sets from $2C
        lda     IMG_BUF+IMG_CTRL
        jsr     G_CTRLSW
        lda     IMG_BUF+IMG_CHR0
        jsr     G_CHR0SW
        jsr     rs_vram_ptr
        lda     #$20
        jsr     rs_nt_write
        jsr     rs_nt2
        jsr     rs_nt_write
        lda     #$3F
        sta     PPU_ADDR
        lda     #$00
        sta     PPU_ADDR
        ldx     #0
:       lda     IMG_BUF+IMG_PAL,x
        sta     PPU_DATA
        inx
        cpx     #32
        bne     :-
        jmp     rs_ppu_on
.endproc

; ZP_PTR = IMG_BUF+IMG_RAM2, ZP_PTR2 = $0200, X = 6 pages
.proc rs_ram2_ptrs
        lda     #<(IMG_BUF+IMG_RAM2)
        sta     ZP_PTR
        lda     #>(IMG_BUF+IMG_RAM2)
        sta     ZP_PTR+1
        lda     #$00
        sta     ZP_PTR2
        lda     #$02
        sta     ZP_PTR2+1
        ldx     #6
        rts
.endproc

; ZP_PTR = IMG_BUF+IMG_VRAM
.proc rs_vram_ptr
        lda     #<(IMG_BUF+IMG_VRAM)
        sta     ZP_PTR
        lda     #>(IMG_BUF+IMG_VRAM)
        sta     ZP_PTR+1
        rts
.endproc

; rs_nt2 -- A = the high byte of the second physical nametable: $28 under
; horizontal mirroring (MMC1 control bits 1-0 = 3), $24 otherwise.
.proc rs_nt2
        lda     CTRL_SH
        and     #3
        cmp     #3
        beq     :+
        lda     #$24
        rts
:       lda     #$28
        rts
.endproc

; rs_nt_read / rs_nt_write -- 1K between PPU (A << 8) and (ZP_PTR), which
; advances by four pages.
.proc rs_nt_read
        sta     PPU_ADDR
        lda     #$00
        sta     PPU_ADDR
        lda     PPU_DATA        ; reads lag one behind: prime the buffer
        ldx     #4
@v:     ldy     #0
:       lda     PPU_DATA
        sta     (ZP_PTR),y
        iny
        bne     :-
        inc     ZP_PTR+1
        dex
        bne     @v
        rts
.endproc

.proc rs_nt_write
        sta     PPU_ADDR
        lda     #$00
        sta     PPU_ADDR
        ldx     #4
@v:     ldy     #0
:       lda     (ZP_PTR),y
        sta     PPU_DATA
        iny
        bne     :-
        inc     ZP_PTR+1
        dex
        bne     @v
        rts
.endproc

.proc rs_ppu_off
        lda     G_PPUCTRL
        and     #%01111011      ; NMI off, +1 increments
        sta     PPU_CTRL
        lda     #0
        sta     PPU_MASK
        bit     PPU_STATUS
        rts
.endproc

; back to the game's own settings; its next NMI rewrites the scroll
.proc rs_ppu_on
        bit     PPU_STATUS
        lda     #0
        sta     PPU_SCROLL
        sta     PPU_SCROLL
        lda     G_PPUCTRL
        sta     PPU_CTRL
        lda     G_PPUMASK
        sta     PPU_MASK
        rts
.endproc
