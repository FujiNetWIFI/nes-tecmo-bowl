; fix.s -- the hooks that live in the fixed bank. tools/patches.py names
; every site that jumps here. The NMI and the scheduler run with any bank
; mapped at $8000, and the NMI's crash guard ($C06F) forbids running from
; WRAM, so this code sits in the fixed bank's free space (FIXA = $C290,
; FIXB = $CD96; both read as zero and nothing reads them: profile.lua).
;
; Net mode in one paragraph: a sim tick runs from one scheduler-idle point
; to the next. When the scheduler finds nothing to run, W_IDLE sets IDLE and
; hands the main thread to NET_IDLE in bank 8. The first full NMI after that
; does the game's whole display pass (VRAM list, field column, CHR0 request)
; and sets TICK_DUE; every other NMI only re-asserts the PPU registers and
; writes no RAM at all. NET_IDLE then runs LS_TICK -- pads, RNG, frame
; counter and wakeups, the parts of the stock NMI that a lag frame would
; otherwise land in the middle of a task -- and restarts the scheduler.
; With NET_MODE = 0 every hook does exactly what the bytes it replaced did.

        .segment "FIXA"

; W_RESET -- the reset vector. The game's stub at $FFE0 is copied here so
; that "FUJI" can take $FFF0-$FFF3, where the stub's loop used to be.
W_RESET:
        lda     #$10
        sta     PPU_CTRL
        lda     #$80
        sta     $8000
        lda     #$1E
        ldx     #5
:       sta     $8000
        lsr     a
        dex
        bne     :-
        jmp     $C000

; W_STUB -- replaces the NMI's "busy" exit at $C064 (PHA / LDA $2002 / PLA /
; RTI), taken when $0A bit 7 is clear. Counts the frame: lockstep timeouts
; are in frames, never in pump rounds.
W_STUB:
        pha
        lda     PPU_STATUS
        inc     NMI_SEEN
        pla
        rti

; W_DISP -- replaces LDA $CC / BPL $C0A2 at $C087, after the OAM DMA.
W_DISP:
        lda     NET_MODE
        beq     @stock
        inc     NMI_SEEN
        lda     IDLE
        beq     @lag            ; a task is running
        lda     TICK_DUE
        bne     @lag            ; this tick's display pass is done
        inc     TICK_DUE
@stock: lda     G_CHR0REQ
        bpl     @nochr
        pha
        and     #$1F
        sta     CHR0_SH
        pla
        jmp     G_NMI_CHR0
@nochr: jmp     G_NMI_NOCHR0
@lag:   inc     LAGN_LO
        bne     :+
        inc     LAGN_HI
:       jmp     W_LAGDISP

; W_SIM -- replaces LDY #4 / LDA $0D at $C1FF, the start of the pad read.
; Net mode: no pads, RNG or frame counter here (LS_TICK does them); on to
; the sprite-0 wait.
W_SIM:
        lda     NET_MODE
        bne     @net
        ldy     #4
        lda     G_HELD1
        jmp     G_NMI_PAD
@net:   jmp     G_NMI_S0WAIT

; W_WAKE -- replaces JMP $C500 at $C28D. Net mode: no wakeups or
; preemption here (LS_TICK wakes; the scheduler is idle, so a preemption
; would only have rescanned).
W_WAKE:
        lda     NET_MODE
        bne     @net
        jmp     G_NMI_WAKE
@net:   jmp     G_NMI_EXIT

; W_IDLE -- the scheduler's scan found nothing ready (patched over CPX #0 /
; BNE / BEQ $C559 at $C569). Net mode: hand the main thread to NET_IDLE,
; which sets IDLE and returns through G_SCHED.
W_IDLE:
        lda     NET_MODE
        bne     @net
        jmp     G_RESCAN
@net:   lda     #NET_BANK
        jsr     G_PRGSW
        jmp     NET_IDLE

; W_BOOT -- replaces JSR $C5EE (spawn task $80) at $C044, after the RAM
; clear and before the NMI goes on. A and X are the spawn's arguments.
W_BOOT:
        pha
        txa
        pha
        lda     #NET_BANK
        jsr     G_PRGSW
        jsr     NET_BOOT
        pla
        tax
        pla
        jmp     G_SPAWN

; W_CTRL / W_CHR0 -- replace LSR $0A / STA (first byte) at $C87E and $C897:
; keep a copy of what the game writes, for the resync image.
W_CTRL:
        sta     CTRL_SH
        lsr     G_NMIARM
        sta     $8000
        jmp     G_CTRLSW+5
W_CHR0:
        sta     CHR0_SH
        lsr     G_NMIARM
        sta     $A000
        jmp     G_CHR0SW+5

        .segment "FIXB"

; W_LAGDISP -- a lag NMI's display pass (from W_DISP): what the tick NMI's
; $C0A2-$C1FE and task $D0's status-bar split ($8094 in bank 2) would leave
; in the PPU and CHR1 this frame, with no RAM writes at all. Stock, a lag
; frame preempts the running task so $D0 can do its split; here the NMI
; does it, at the same cost: a wait for the sprite-0 hit.
W_LAGDISP:
        ; the top: rendering on, PPUCTRL with the nametable bits from
        ; $BF/$DF, the scroll, the status bar's CHR1
        lda     G_PPUMASK
        ora     #$18
        sta     PPU_MASK
        lda     G_SCROLLXH
        lsr     a
        lda     G_SCROLLYH
        rol     a
        and     #$03
        pha
        lda     G_PPUCTRL
        and     #$FC
        tsx
        ora     $0101,x
        sta     PPU_CTRL
        pla
        lda     G_SCROLLX
        sta     PPU_SCROLL
        lda     G_SCROLLY
        sta     PPU_SCROLL
        lda     G_CHR1
        jsr     w_chr1
        ; the split, unless this screen has none ($DD bit 7)
        bit     G_SPLIT
        bmi     @done
:       bit     PPU_STATUS      ; last frame's hit: wait for the pre-render
        bvs     :-              ;   line to clear it
        ldx     #0              ; then the hit, with $D0's own timeout
        ldy     #4
@hit:   bit     PPU_STATUS
        bvs     @split
        dex
        bne     @hit
        dey
        bne     @hit
@split: lda     G_SPLITXH       ; PPUCTRL bit 0 from $BB
        lsr     a
        lda     G_PPUCTRL
        and     #$FE
        adc     #0
        sta     PPU_CTRL
        lda     G_SPLITX
        sta     PPU_SCROLL
        lda     G_SCROLLY
        sta     PPU_SCROLL
        bit     G_SPLIT         ; the field's CHR1: $2D, or the frame
        bvs     @c2d            ;   counter's animated $10-$13
        lda     G_FRAME
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        and     #$03
        clc
        adc     #$10
        bne     @chr
@c2d:   lda     G_CHR1SPLIT
@chr:   jsr     w_chr1
@done:  jmp     G_NMI_EXIT

; w_chr1 -- A to MMC1 CHR1. NMI context only: the NMI is never entered in
; the middle of a guarded serial write.
w_chr1:
        sta     $C000
        lsr     a
        sta     $C000
        lsr     a
        sta     $C000
        lsr     a
        sta     $C000
        lsr     a
        sta     $C000
        rts
