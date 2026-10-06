; mailbox.s -- FujiBus transactions through the cartridge mailbox, and the
; N: (TCP) and appkey calls built on them.
;
; A transaction: DEVICE, CMD, NPARAM, rewind the TX stream, append each
; parameter as {size, value bytes LE} then the payload, then launch by
; writing SEQ = ACKSEQ + 1 (never 0, and never from a counter of ours: a
; console reset does not reset the cart). The cart publishes ACKSEQ last,
; after the reply is in place.
;
; Every store into $5500-$57FF is a plain STA/STX/STY. tools/checkrom.py
; rejects an RMW there: its dummy write would land as a spurious event.

; MB_BEGIN -- A = device, X = command, Y = parameter count.
.proc MB_BEGIN
        sta     FN_RSEL+FR_DEV
        stx     FN_RSEL+FR_CMD
        sty     FN_RSEL+FR_NPAR
        lda     #0
        sta     FN_RSEL+FR_DRST ; rewind last: parameters may follow at once
        rts
.endproc

; MB_P1 -- append a one-byte parameter, value A.
.proc MB_P1
        ldx     #1
        stx     FN_TX
        sta     FN_TX
        rts
.endproc

; MB_P2 -- append a two-byte parameter, A = low, X = high.
.proc MB_P2
        ldy     #2
        sty     FN_TX
        sta     FN_TX
        stx     FN_TX
        rts
.endproc

; MB_GO -- launch and wait up to MB_TMO units (~0.55 s each).
; Returns MB_OK = 1 and Z clear on an ACK; MB_OK = 0 and Z set otherwise,
; MB_ERR = the cart's error (0 on our own timeout). Bumps DIAG_TMO/DIAG_ERR.
.proc MB_GO
        lda     FN_ACKS
        clc
        adc     #1
        bne     :+
        lda     #1
:       sta     MB_SEQ
        sta     FN_RSEL+FR_SEQ
        lda     MB_TMO
        sta     MB_CNT
@o:     ldy     #0
@m:     ldx     #0
@i:     lda     FN_ACKS
        cmp     MB_SEQ
        beq     @got
        dex
        bne     @i
        lda     HUD_POLL        ; a whole inner pass: count it
        cmp     #$FF
        beq     :+
        inc     HUD_POLL
:       dey
        bne     @m
        dec     MB_CNT
        bne     @o
        ; timed out. The cart may still finish the request after we walk
        ; away -- a READ we gave up on can swallow bytes -- so count it.
        lda     #0
        sta     MB_ERR
        lda     DIAG_TMO
        cmp     #$FF
        beq     @fail
        inc     DIAG_TMO
        jmp     @fail
@got:   lda     FN_ERR
        bne     @err
        lda     FN_RCMD
        cmp     #$06
        beq     @ok
        lda     #$90            ; NAK: the SIO "device error"
@err:   sta     MB_ERR
        lda     DIAG_ERR
        cmp     #$FF
        beq     @fail
        inc     DIAG_ERR
@fail:  lda     #0
        sta     MB_OK
        rts
@ok:    lda     #1
        sta     MB_OK
        rts
.endproc

; MB_MAGIC -- Z clear (A=1) if the cartridge answers 'F','N'.
.proc MB_MAGIC
        lda     FN_MAG0
        cmp     #'F'
        bne     @no
        lda     FN_MAG1
        cmp     #'N'
        bne     @no
        lda     #1
        rts
@no:    lda     #0
        rts
.endproc

; ---------------------------------------------------------------- N:
; NET_STATUS -- bytes waiting on N1. NAVAIL_LO/HI (0 on failure). The reply
; is avail_lo, avail_hi, connected, error; error != 1 is a failure too.
.proc NET_STATUS
        lda     #FNDEV_N1
        ldx     #NETCMD_STATUS
        ldy     #2
        jsr     MB_BEGIN
        lda     #0
        jsr     MB_P1
        lda     #0
        jsr     MB_P1
        lda     #MB_TMO_FAST
        sta     MB_TMO
        jsr     MB_GO
        beq     @fail
        lda     FN_RPLY+3
        cmp     #1
        beq     @ok
        sta     MB_ERR
        lda     #0
        sta     MB_OK
        beq     @fail
@ok:    lda     FN_RPLY
        sta     NAVAIL_LO
        lda     FN_RPLY+1
        sta     NAVAIL_HI
        rts
@fail:  lda     #0
        sta     NAVAIL_LO
        sta     NAVAIL_HI
        rts
.endproc

; NET_READ -- read NREQ bytes into the reply window; NGOT = how many came.
; Never ask for more than NET_STATUS said is there: a short read is an
; error-and-timeout on this firmware, not a short read.
.proc NET_READ
        lda     #FNDEV_N1
        ldx     #NETCMD_READ
        ldy     #1
        jsr     MB_BEGIN
        lda     NREQ
        ldx     #0
        jsr     MB_P2
        lda     #MB_TMO_FAST
        sta     MB_TMO
        jsr     MB_GO
        beq     @fail
        lda     FN_RXHI
        bne     @cap
        lda     FN_RXLO
        cmp     NREQ
        bcc     @st
@cap:   lda     NREQ            ; never more than we asked for
@st:    sta     NGOT
        rts
@fail:  lda     #0
        sta     NGOT
        rts
.endproc

; NET_WRITE -- send X bytes from TXBUF.
.proc NET_WRITE
        stx     NREQ
        lda     #FNDEV_N1
        ldx     #NETCMD_WRITE
        ldy     #1
        jsr     MB_BEGIN
        lda     NREQ
        ldx     #0
        jsr     MB_P2
        ldx     #0
:       lda     TXBUF,x
        sta     FN_TX
        inx
        cpx     NREQ
        bne     :-
        lda     #MB_TMO_FAST
        sta     MB_TMO
        jmp     MB_GO
.endproc

; NET_OPEN -- open N1 on SRV_BUF (SES_GETSERVER), read-write, no
; translation.
.proc NET_OPEN
        lda     #FNDEV_N1
        ldx     #NETCMD_OPEN
        ldy     #2
        jsr     MB_BEGIN
        lda     #OPEN_MODE_RW
        jsr     MB_P1
        lda     #0
        jsr     MB_P1
        ldx     #0
@spec:  lda     SRV_BUF,x
        beq     :+
        sta     FN_TX
        inx
        bne     @spec
:       lda     #MB_TMO_OPEN
        sta     MB_TMO
        jmp     MB_GO
.endproc

; NET_CLOSE
.proc NET_CLOSE
        lda     #FNDEV_N1
        ldx     #NETCMD_CLOSE
        ldy     #0
        jsr     MB_BEGIN
        lda     #MB_TMO_OPEN
        sta     MB_TMO
        jmp     MB_GO
.endproc

; ---------------------------------------------------------------- appkeys
; AK_OPEN -- open appkey creator 1 / app 1 / key A for reading. The payload
; is six bytes: creator lo/hi, app, key, mode, and a reserved sixth byte the
; firmware waits for (five reads back as a timeout).
.proc AK_OPEN
        pha
        lda     #FNDEV_FUJI
        ldx     #CMD_OPEN_APPKEY
        ldy     #0
        jsr     MB_BEGIN
        lda     #1
        sta     FN_TX           ; creator lo
        lda     #0
        sta     FN_TX           ; creator hi
        lda     #1
        sta     FN_TX           ; app
        pla
        sta     FN_TX           ; key
        lda     #0
        sta     FN_TX           ; mode: read
        sta     FN_TX           ; reserved
        lda     #MB_TMO_FAST
        sta     MB_TMO
        jmp     MB_GO
.endproc

; AK_READ -- the value lands in the reply window as a 2-byte LE length and
; the data (the RS232 FujiBus path prepends the length).
.proc AK_READ
        lda     #FNDEV_FUJI
        ldx     #CMD_READ_APPKEY
        ldy     #0
        jsr     MB_BEGIN
        lda     #MB_TMO_FAST
        sta     MB_TMO
        jmp     MB_GO
.endproc

.proc AK_CLOSE
        lda     #FNDEV_FUJI
        ldx     #CMD_CLOSE_APPKEY
        ldy     #0
        jsr     MB_BEGIN
        lda     #MB_TMO_FAST
        sta     MB_TMO
        jmp     MB_GO
.endproc
