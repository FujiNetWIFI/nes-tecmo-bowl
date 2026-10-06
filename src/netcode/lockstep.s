; lockstep.s -- delay-based input lockstep for Tecmo Bowl.
;
; The sim clock: one tick runs from one scheduler-idle point to the next
; (fix.s has the whole story). NET_IDLE waits, pumping, until the tick NMI
; has done its display pass, then calls LS_TICK, then restarts the
; scheduler, which runs every task the tick woke until none is ready.
;
; Between ticks, NET_IDLE first folds part of the state into the CRC
; (LS_CRC_IDLE) with IDLE still 0, so every NMI meanwhile is a lag NMI and
; writes no RAM; only then does it set IDLE and let the next NMI be the
; tick NMI.
;
; LS_TICK, for tick T:
;   LS_POST   the last tick's epilogue: trace, CRC every 64, T++, resync
;   capture   local pad -> LOC_RING[T+d]; INPUT(T+d) queued for NET_IDLE
;   gate      wait until the peer's watermark reaches T. The wait spins on
;             the main thread with the scheduler idle: the NMIs that fire
;             meanwhile only re-assert the PPU registers (W_DISP), so the
;             screen stays up and no RAM moves under us.
;   feed      both pads by role into the game's raw bytes, then exactly what
;             the stock NMI does after its pad read: edges ($C257), the RNG
;             step ($C26F), INC $03, and the wait-count wakeups ($C500).
;
; Roles: host = the waiting player = 1UP: its local pad is P1 ($07).

LS_TIMEOUT      = $0258         ; gate frames (10 s) before the peer is lost
RS_HOLD_TMO     = $0384         ; hold frames (15 s) before giving up
FUZZ_FROM       = 1200          ; FUZZ: the scripted menus end here

; ---------------------------------------------------------------------------
; NET_IDLE -- the main thread while the scheduler has nothing to run. Entered
; from W_IDLE by a JMP with SP = $FF and this bank mapped; leaves by a JMP to
; G_SCHED. The game's $F4-$F8 are ours in between.
.proc NET_IDLE
        ldx     #ZP_LEN-1
:       lda     ZP_BASE,x
        sta     ZP_SAVE,x
        dex
        bpl     :-
        jsr     LS_CRC_IDLE     ; the state is still: IDLE is 0
        lda     #1
        sta     IDLE
        lda     NET_MODE
        cmp     #1
        bne     @wait
        jsr     LS_FLUSH        ; the INPUT this tick captured
        jsr     SES_PUMP        ; and whatever the peer has sent
        lda     NMI_SEEN
        sta     IDLE_SEEN
@wait:  lda     TICK_DUE
        bne     @tick
        lda     NET_MODE
        cmp     #1
        bne     @wait
        lda     NMI_SEEN        ; a long wait: one more pump per frame
        cmp     IDLE_SEEN
        beq     @wait
        sta     IDLE_SEEN
        jsr     SES_PUMP
        jmp     @wait
@tick:  jsr     LS_TICK
        ldx     #ZP_LEN-1
:       lda     ZP_SAVE,x
        sta     ZP_BASE,x
        dex
        bpl     :-
        lda     #0
        sta     IDLE            ; first: the next NMI is a lag NMI
        sta     TICK_DUE
        jmp     G_SCHED
.endproc

; ---------------------------------------------------------------------------
; LS_START -- arm the engine at tick 0 (from START, or a SOLO boot).
.proc LS_START
        lda     #0
        tax
:       sta     LOC_RING,x
        sta     RMT_RING,x
        inx
        bne     :-
        sta     TICK_LO
        sta     TICK_HI
        sta     RMT_WM_HI
        sta     NET_DROPPED
        sta     PEER_SCR
        sta     RESYNC_HOLD
        sta     RS_PEND
        sta     RS_ENDP
        sta     LS_WAITC_LO
        sta     LS_WAITC_HI
        sta     POST_PEND
        sta     TXIN_PEND
        lda     #$FF
        sta     CK_NEXT
        lda     NET_DELAY
        sec
        sbc     #1
        sta     RMT_WM_LO       ; ticks 0..d-1 are known: idle
        jsr     RS_CLR_CRC
        ; the game's RNG from the server's seed (the game itself starts it at
        ; zero): both consoles run the same sequence, a new one every match
        lda     SEED_LO
        sta     G_RNG
        lda     SEED_HI
        sta     G_RNG+1
        ; fuzz streams, per side, so a rig is reproducible
        lda     #$34
        ldx     #$12
        ldy     NET_ROLE
        beq     :+
        lda     #$78
        ldx     #$56
:       sta     FUZ_LO
        stx     FUZ_HI
        lda     #$78
        sta     FUZ2_LO
        lda     #$56
        sta     FUZ2_HI
        lda     #$E1
        sta     JIT_LO
        lda     #$AC
        sta     JIT_HI
        lda     #0
        sta     FUZ_CUR
        sta     FUZ_CUR+2
        rts
.endproc

; LS_SOLO_INIT -- SOLO builds: lockstep with no network. The "peer" is
; controller 2 (or a second fuzz stream), delayed like a real peer.
.proc LS_SOLO_INIT
        lda     #SOLO_DELAY
        sta     NET_DELAY
        lda     #0
        sta     NET_ROLE
        lda     #$E1
        sta     SEED_LO
        lda     #$AC
        sta     SEED_HI
        jsr     LS_START
        lda     #1
        sta     NET_ACTIVE
        rts
.endproc

; LS_IDLE_RMT -- peer gone: idle the remote ring, pin the watermark far
; ahead.
.proc LS_IDLE_RMT
        lda     #0
        tax
:       sta     RMT_RING,x
        inx
        bne     :-
        lda     TICK_LO
        sta     RMT_WM_LO
        lda     TICK_HI
        clc
        adc     #$40
        sta     RMT_WM_HI
        rts
.endproc

; LS_FLUSH -- send the queued INPUT frame, if any.
.proc LS_FLUSH
        lda     TXIN_PEND
        beq     @out
        lda     #0
        sta     TXIN_PEND
        ldx     #5
:       lda     TXIN,x
        sta     TXBUF,x
        dex
        bpl     :-
        ldx     #6
        jmp     NET_WRITE
@out:   rts
.endproc

; ---------------------------------------------------------------------------
; LS_TICK -- one tick. From NET_IDLE, once the tick NMI has run.
.proc LS_TICK
        lda     #1
        sta     IN_TICK
        lda     POST_PEND
        beq     @top
        jsr     LS_POST
@top:   lda     NET_DROPPED
        beq     :+
        jmp     LS_GONE
:       lda     RESYNC_HOLD
        beq     @tick
        jsr     LS_HOLD
        jmp     @top
@tick:  ; ---- capture local input for t = T+d ----------------------------
        lda     TICK_LO         ; first: the fuzz script runs on t
        clc
        adc     NET_DELAY
        sta     ZP_PTR2
        lda     TICK_HI
        adc     #0
        sta     ZP_PTR2+1
        jsr     LS_LOCAL        ; A = ours, ZP_T2 = controller 2 (SOLO)
        sta     LOCAL_IN
        ldx     ZP_PTR2
        lda     LOCAL_IN
        sta     LOC_RING,x
        lda     NET_MODE
        cmp     #2
        beq     @solo
        ; INPUT: [5][06][tick_lo][tick_hi][pad][0], sent by NET_IDLE once
        ; this tick's tasks are done (or by the gate, if it has to wait)
        lda     #5
        sta     TXIN
        lda     #FT_INPUT
        sta     TXIN+1
        lda     ZP_PTR2
        sta     TXIN+2
        lda     ZP_PTR2+1
        sta     TXIN+3
        lda     LOCAL_IN
        sta     TXIN+4
        lda     #0
        sta     TXIN+5
        lda     #1
        sta     TXIN_PEND
        jmp     @gate
@solo:  jsr     LS_SOLO_RMT
        ldx     ZP_PTR2
        sta     RMT_RING,x
        lda     ZP_PTR2
        sta     RMT_WM_LO
        lda     ZP_PTR2+1
        sta     RMT_WM_HI
@gate:
.if ::STALL_N > 0
        ; test builds: a STALL_N-frame stall every 64 ticks, to prove the
        ; sim does not care how long a tick takes
        lda     TICK_LO
        and     #$3F
        cmp     #$20
        bne     @nost
        lda     NMI_SEEN
        clc
        adc     #STALL_N
        sta     STALL_CNT
:       lda     NMI_SEEN
        cmp     STALL_CNT
        bne     :-
@nost:
.endif
        lda     NMI_SEEN
        sta     LS_TMP
        lda     #0
        sta     LS_WAITC_LO
        sta     LS_WAITC_HI
@g:     ; WM - T >= 0 ?
        lda     RMT_WM_LO
        sec
        sbc     TICK_LO
        sta     ZP_T3
        lda     RMT_WM_HI
        sbc     TICK_HI
        bpl     @run
        ; ---- stall -------------------------------------------------------
        lda     #0
        sta     HUD_LEAD
        lda     HUD_STL
        cmp     #$FF
        beq     :+
        inc     HUD_STL
:       jsr     LS_FLUSH        ; the peer may be waiting on us, too
        jsr     SES_PUMP
        lda     NET_DROPPED
        beq     :+
        jmp     LS_GONE
:       lda     RESYNC_HOLD     ; a BEGIN landed while we waited
        beq     :+
        jsr     LS_HOLD
        jmp     @top
:       lda     NMI_SEEN        ; count frames, not pumps: a pump can take
        cmp     LS_TMP          ;   no emulated time at all under MAME
        beq     @g
        sta     LS_TMP
        inc     LS_WAITC_LO
        bne     :+
        inc     LS_WAITC_HI
:       lda     LS_WAITC_HI
        cmp     #>LS_TIMEOUT
        bcc     @g
        lda     LS_WAITC_LO
        cmp     #<LS_TIMEOUT
        bcc     @g
        lda     #0
        sta     PEER_WHY        ; we timed out, no clean goodbye
        lda     #1
        sta     NET_DROPPED
        jmp     LS_GONE
@run:   ; slack, for the rigs: how many ticks of remote input in hand
        bne     @lead15
        lda     ZP_T3
        cmp     #16
        bcc     :+
@lead15:
        lda     #15
:       sta     HUD_LEAD
        ; ---- feed the pair by role ----------------------------------------
        ldx     TICK_LO
        lda     LOC_RING,x
        ldy     RMT_RING,x
        ldx     NET_ROLE
        bne     @guest
        sta     G_PADRAW1       ; host: we are P1
        sty     G_PADRAW2
        jmp     @fed
@guest: sty     G_PADRAW1
        sta     G_PADRAW2
@fed:   ; ---- the rest of the stock NMI, from $C257 ------------------------
        lda     G_HELD1         ; edges: new = (held ^ raw) & raw
        eor     G_PADRAW1
        and     G_PADRAW1
        sta     G_NEW1
        lda     G_PADRAW1
        sta     G_HELD1
        lda     G_HELD2
        eor     G_PADRAW2
        and     G_PADRAW2
        sta     G_NEW2
        lda     G_PADRAW2
        sta     G_HELD2
        clc                     ; the RNG step ($C26F)
        lda     G_RNG
        adc     #$83
        sta     G_RNG
        lda     G_RNG+1
        adc     #$0D
        sta     G_RNG+1
        lda     G_RNG+2
        adc     #$11
        sta     G_RNG+2
        inc     G_FRAME
        ; the wakeups ($C500-$C51F): every waiting task's count down by one;
        ; at zero it is ready ($13), and $01 ends up the highest woken
        ldx     #$F0
        ldy     #8
        lda     #0
        sta     G_WOKEN
@w:     lda     $00,x
        cmp     #$11
        bne     @nx
        dec     $01,x
        bne     @nx
        lda     #$13
        sta     $00,x
        stx     G_WOKEN
@nx:    txa
        sec
        sbc     #$10
        tax
        dey
        bne     @w
.if ::JITTER
        jsr     LS_JITTER
.endif
        lda     #1
        sta     POST_PEND
        lda     #0
        sta     IN_TICK
        rts
.endproc

; LS_HOLD -- resync hold: the sim stays frozen here, pumping, until the
; END frame rebases us (RESYNC_HOLD back to 0) or the peer is lost.
.proc LS_HOLD
        lda     NMI_SEEN
        sta     LS_TMP
        lda     #0
        sta     RS_TO_LO
        sta     RS_TO_HI
@l:     lda     RS_ENDP         ; END came in while we were idle
        beq     :+
        lda     #0
        sta     RS_ENDP
        jsr     RS_APPLY
        jmp     RS_REBASE
:       jsr     SES_PUMP
        lda     RESYNC_HOLD
        beq     @out
        lda     NET_DROPPED
        bne     @out
        lda     HUD_HLD
        cmp     #$FF
        beq     :+
        inc     HUD_HLD
:       lda     NMI_SEEN
        cmp     LS_TMP
        beq     @l
        sta     LS_TMP
        inc     RS_TO_LO
        bne     :+
        inc     RS_TO_HI
:       lda     RS_TO_HI
        cmp     #>RS_HOLD_TMO
        bcc     @l
        lda     RS_TO_LO
        cmp     #<RS_HOLD_TMO
        bcc     @l
        lda     #0
        sta     PEER_WHY
        sta     RESYNC_HOLD
        lda     #1
        sta     NET_DROPPED
@out:   rts
.endproc

; ---------------------------------------------------------------------------
; LS_POST -- the epilogue of tick T, run at the start of the next LS_TICK.
; CRC_LO/HI were folded between the ticks (LS_CRC_IDLE).
.proc LS_POST
        lda     #0
        sta     POST_PEND
.if ::TRACE
        ; test builds: every tick's checksum into a 1024-tick ring
        lda     TICK_LO         ; (T & 1023) * 2, TRACE_BUF page aligned
        asl     a
        sta     ZP_PTR
        lda     TICK_HI
        and     #$03
        rol     a
        adc     #>TRACE_BUF
        sta     ZP_PTR+1
        ldy     #0
        lda     CRC_LO
        sta     (ZP_PTR),y
        iny
        lda     CRC_HI
        sta     (ZP_PTR),y
.endif
        lda     TICK_LO
        and     #$3F
        bne     @nocrc
.if ::TRACE = 0
        lda     CK_NEXT
        cmp     #4
        bne     @nocrc          ; void: a resync cut this one short
        lda     #$FF
        sta     CK_NEXT
.endif
        jsr     RS_RECORD_CRC
        lda     NET_MODE
        cmp     #1
        bne     @nocrc
        lda     #5
        sta     TXBUF
        lda     #FT_CRC
        sta     TXBUF+1
        lda     TICK_LO
        sta     TXBUF+2
        lda     TICK_HI
        sta     TXBUF+3
        lda     CRC_LO
        sta     TXBUF+4
        lda     CRC_HI
        sta     TXBUF+5
        ldx     #6
        jsr     NET_WRITE
@nocrc: inc     TICK_LO
        bne     :+
        inc     TICK_HI
:       lda     NET_MODE
        cmp     #1
        bne     :+
        jmp     RS_PENDING
:       rts
.endproc

; LS_CRC_IDLE -- from NET_IDLE, after tick T's tasks and before the tick
; NMI, with IDLE 0 so nothing writes RAM under us. The CRC for every 64th
; tick is folded over four ticks, a quarter of the state each (T & $3F =
; $3D, $3E, $3F, $00), so no tick pays for all of it: the label is the last
; tick, and both consoles fold the same bytes at the same ticks. A resync
; can land mid-fold; CK_NEXT then voids that CRC. TRACE builds fold
; everything, every tick.
.proc LS_CRC_IDLE
        lda     POST_PEND
        beq     @out            ; no tick has run since START or a rebase
.if ::TRACE
        lda     #0
        sta     CRC_LO
        sta     CRC_HI
        ldx     #0
:       stx     CK_NEXT
        jsr     LS_CKPART
        ldx     CK_NEXT
        inx
        cpx     #4
        bne     :-
.else
        lda     TICK_LO
        clc
        adc     #3
        and     #$3F
        cmp     #4
        bcs     @out
        tax                     ; the part: 0-3
        bne     :+
        lda     #0
        sta     CRC_LO
        sta     CRC_HI
        sta     CK_NEXT
:       cpx     CK_NEXT
        bne     @out
        jsr     LS_CKPART
        inc     CK_NEXT
.endif
@out:   rts
.endproc

; ---------------------------------------------------------------------------
; LS_LOCAL -- this console's input for the tick being captured: controller
; 1. ZP_T2 = controller 2, for SOLO builds.
.proc LS_LOCAL
.if ::FUZZ
        lda     NET_ROLE
        jsr     LS_FUZZ_SIDE    ; X = 0: our stream
        pha
        lda     #1
        ldx     #2
        jsr     LS_FUZZ_STEP    ; the SOLO peer's stream, kept in step
        sta     ZP_T2
        pla
        rts
.else
        lda     NET_MODE
        cmp     #2
        bne     @one
        lda     PAD2_LAST
        ldx     #1
        jsr     LS_READ
        sta     PAD2_LAST
        sta     ZP_T2
@one:   lda     LOCAL_IN
        ldx     #0
        jmp     LS_READ
.endif
.endproc

.if ::FUZZ = 0
; LS_READ -- X = port (0 or 1), A = its last reading; A = buttons. The
; stock reader's DPCM guard ($C1FF): sample DMA can clock the port an
; extra time, so read until two reads agree -- the first one with the last
; reading -- and after four disagreements keep the last reading.
.proc LS_READ
        sta     RD_PREV
        sta     RD_LAST
        stx     ZP_T3
        ldy     #4
@try:   lda     #1
        sta     $4016
        lda     #0
        sta     $4016
        lda     #8
        sta     ZP_T1
        ldx     ZP_T3
@b:     lda     $4016,x
        lsr     a
        rol     RD_CUR
        and     #1              ; D0 | D1: a standard or expansion pad
        ora     RD_CUR
        sta     RD_CUR
        dec     ZP_T1
        bne     @b
        lda     RD_CUR
        cmp     RD_PREV
        beq     @ok
        sta     RD_PREV
        dey
        bne     @try
        lda     RD_LAST
@ok:    rts
.endproc
.endif

; LS_SOLO_RMT -- SOLO builds: the "peer's" input for T+d.
.proc LS_SOLO_RMT
        lda     ZP_T2
        rts
.endproc

.if ::FUZZ
; LS_FUZZ_SIDE -- A = side (0 host, 1 guest) for our own stream at X = 0.
.proc LS_FUZZ_SIDE
        ldx     #0
        jmp     LS_FUZZ_STEP
.endproc

; LS_FUZZ_STEP -- A = side, X = stream (0 = FUZ, 2 = FUZ2). The input this
; side presses at the tick being captured (t = T+d). Up to FUZZ_FROM a
; script walks the menus (FZ_TAB); then both sides get a new random pad
; every 8 ticks, Start and Select masked out.
.proc LS_FUZZ_STEP
        sta     ZP_T3
        lda     ZP_PTR2
        cmp     #<FUZZ_FROM
        lda     ZP_PTR2+1
        sbc     #>FUZZ_FROM
        bcs     @fuzz
        ldy     #0
@e:     lda     FZ_TAB,y
        bmi     @idle
        cmp     ZP_T3
        bne     @next
        lda     ZP_PTR2         ; t >= from?
        cmp     FZ_TAB+1,y
        lda     ZP_PTR2+1
        sbc     FZ_TAB+2,y
        bcc     @next
        lda     ZP_PTR2         ; t < to?
        cmp     FZ_TAB+3,y
        lda     ZP_PTR2+1
        sbc     FZ_TAB+4,y
        bcs     @next
        lda     FZ_TAB+5,y
        rts
@next:  tya
        clc
        adc     #6
        tay
        jmp     @e
@idle:  lda     #0
        rts
@fuzz:  lda     ZP_PTR2
        and     #7
        bne     @hold
        ; xorshift16 (7, 9, 8)
        lda     FUZ_HI,x
        lsr     a
        lda     FUZ_LO,x
        ror     a
        eor     FUZ_HI,x
        sta     FUZ_HI,x
        ror     a
        eor     FUZ_LO,x
        sta     FUZ_LO,x
        eor     FUZ_HI,x
        sta     FUZ_HI,x
        and     #$CF
        sta     FUZ_CUR,x
@hold:  lda     FUZ_CUR,x
        rts
.endproc

; side, from, to (ticks), pad. Title: Start, Select (2PLAYERS), Start; team
; select: each side's A (the host's pad is P1, the guest's P2).
FZ_TAB:
        .byte   0
        .word   180, 186
        .byte   $10
        .byte   0
        .word   360, 366
        .byte   $20
        .byte   0
        .word   420, 426
        .byte   $10
        .byte   0
        .word   540, 546
        .byte   $80
        .byte   1
        .word   600, 606
        .byte   $80
        .byte   $FF
.endif

.if ::JITTER
; LS_JITTER -- det B: hold the tick's tasks back 0-31 x ~1300 cycles (up to
; about 1.4 frames), a different amount every tick, so they run at a
; different place in the frame and some overrun into lag NMIs.
.proc LS_JITTER
        lda     JIT_HI
        lsr     a
        lda     JIT_LO
        ror     a
        eor     JIT_HI
        sta     JIT_HI
        ror     a
        eor     JIT_LO
        sta     JIT_LO
        eor     JIT_HI
        sta     JIT_HI
        and     #$1F
        tay
        beq     @out
@o:     ldx     #0
@i:     dex
        bne     @i
        dey
        bne     @o
@out:   rts
.endproc
.endif

; ---------------------------------------------------------------------------
; LS_CKPART -- X = part (0-3): fold that part of the sim state into
; CRC_LO/HI, Fletcher style (lo += b; hi += lo; the carries ride along).
;
; Everything the sim owns, minus what is not deterministic or not the sim's:
; $0A (the NMI arm flag: the idle scan's SEC/ROR runs a timing-dependent
; number of times), $0C (the NMI's own bank save), the sound engine ($70-$7F,
; $0700-$07D7: it reads $4015, real-time DMC status; nothing else reads its
; RAM -- profile.lua), our borrowed $F4-$F8, and the stack page (dead bytes
; below each task's SP differ with the sound engine's path).
.proc LS_CKPART
        lda     CK_PARTS,x
        sta     ZP_T2
@reg:   ldx     ZP_T2
        lda     CK_TBL+2,x
        beq     @done
        sta     ZP_T1
        lda     CK_TBL,x
        sta     ZP_PTR
        lda     CK_TBL+1,x
        sta     ZP_PTR+1
        inx
        inx
        inx
        stx     ZP_T2
        ldy     #0
        lda     CRC_HI
        sta     ZP_TMP
        lda     CRC_LO
        clc
@b:     adc     (ZP_PTR),y
        tax
        adc     ZP_TMP
        sta     ZP_TMP
        txa
        iny
        cpy     ZP_T1
        bne     @b
        sta     CRC_LO
        lda     ZP_TMP
        sta     CRC_HI
        jmp     @reg
@done:  rts
.endproc

; address, count (1-255); an entry of count 0 ends a part
CK_TBL:
CK_P0:  .word   $0000
        .byte   $0A             ; $00-$09
        .word   $000B
        .byte   1               ; $0B
        .word   $000D
        .byte   $70-$0D         ; $0D-$6F
        .word   $0080
        .byte   $F4-$80         ; $80-$F3 tasks
        .word   $00F9
        .byte   7               ; $F9-$FF
        .word   $07D8
        .byte   $28             ; $07D8-$07FF play data
        .word   0
        .byte   0
CK_P1:  .word   $0200
        .byte   255
        .word   $02FF
        .byte   255
        .word   $03FE
        .byte   2               ; $0200-$03FF
        .word   0
        .byte   0
CK_P2:  .word   $0400
        .byte   255
        .word   $04FF
        .byte   255
        .word   $05FE
        .byte   2               ; $0400-$05FF
        .word   0
        .byte   0
CK_P3:  .word   $0600
        .byte   255
        .word   $06FF
        .byte   1               ; $0600-$06FF
        .word   0
        .byte   0
CK_PARTS:
        .byte   CK_P0-CK_TBL, CK_P1-CK_TBL, CK_P2-CK_TBL, CK_P3-CK_TBL

; ---------------------------------------------------------------------------
; LS_GONE -- the peer is gone (PEER_WHY says how). The sim cannot advance
; without the peer's input, so this never returns: NMI off, our own screen
; with the opponent's name and the four field-diagnostic counters (the one
; time a player on real hardware can read them), and a spin until reset.
.proc LS_GONE
        lda     #1
        sta     PEER_SCR
        jsr     UI_OFF
        lda     #0
        sta     $4015           ; the last notes would drone forever
        jsr     UI_INIT
        jsr     UI_END
        lda     PEER_WHY
        beq     @lost
        lda     #<STR_GONE
        ldx     #>STR_GONE
        ldy     #9
        jmp     @say
@lost:  lda     #<STR_LOST
        ldx     #>STR_LOST
        ldy     #8
@say:   sta     ZP_PTR
        stx     ZP_PTR+1
        ldx     #8
        jsr     UI_PRINT
        lda     #<OPP_NAME
        sta     ZP_PTR
        lda     #>OPP_NAME
        sta     ZP_PTR+1
        ldx     #11
        ldy     #12
        jsr     UI_PRINT
        lda     #<STR_RESET
        sta     ZP_PTR
        lda     #>STR_RESET
        sta     ZP_PTR+1
        ldx     #15
        ldy     #10
        jsr     UI_PRINT
        lda     #<STR_DIAG
        sta     ZP_PTR
        lda     #>STR_DIAG
        sta     ZP_PTR+1
        ldx     #19
        ldy     #8
        jsr     UI_PRINT
        jsr     UI_BEGIN
        lda     #21
        sta     UI_ROW
        lda     #9
        sta     UI_COL
        lda     DIAG_SLIP
        jsr     UI_HEX2
        lda     #13
        sta     UI_COL
        lda     DIAG_REJ
        jsr     UI_HEX2
        lda     #17
        sta     UI_COL
        lda     DIAG_TMO
        jsr     UI_HEX2
        lda     #21
        sta     UI_COL
        lda     DIAG_ERR
        jsr     UI_HEX2
        jsr     UI_END
@spin:  jmp     @spin
.endproc
