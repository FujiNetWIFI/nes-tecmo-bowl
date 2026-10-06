; session.s -- pre-game netplay session: FujiNet check, Lobby-username
; appkey, server connect, HELLO, lobby list / opponent select, START.
; Runs from boot with NMI off, before the game's first frame. Leaves
; NET_MODE = 1 (netplay armed) or 0 (no FujiNet / no server / player chose
; local: the stock game).
;
; Also home to the transport pump and the frame dispatcher the lockstep
; engine uses, as in the Intellivision ports.

.ifndef GUEST_SEED
GUEST_SEED = 0
.endif
.ifndef GAME_APPKEY
GAME_APPKEY = 41                ; the Lobby room's appkey; see run_production.sh
.endif

ROW_TITLE       = 3
ROW_STAT        = 6
ROW_PROMPT      = 9
ROW_LIST        = 11            ; entries on every second row from here
ROW_NOTE        = 27

SES_LIST_FR     = 120           ; LIST every ~2 s of vblanks
SES_HOLD_FR     = 300           ; matched screen: ~5 s, pumping

; ---------------------------------------------------------------------------
.proc SES_MAIN
        jsr     UI_INIT
        jsr     UI_END
        lda     #<STR_TITLE
        sta     ZP_PTR
        lda     #>STR_TITLE
        sta     ZP_PTR+1
        ldx     #ROW_TITLE
        ldy     #7
        jsr     UI_PRINT
        lda     #1
        sta     SES_STATE
        ; ---- a FujiNet? give the cart a couple of seconds to come up
        ldx     #120
:       jsr     MB_MAGIC
        bne     @fn
        jsr     UI_WAITVBL
        dex
        bne     :-
        lda     #<STR_NOFN
        ldx     #>STR_NOFN
        jmp     ses_local_msg
@fn:    lda     #2
        sta     SES_STATE
        ; ---- name, and where to play
        jsr     SES_GETNAME
        jsr     SES_GETSERVER
        lda     #<STR_NAME
        sta     ZP_PTR
        lda     #>STR_NAME
        sta     ZP_PTR+1
        ldx     #ROW_STAT
        ldy     #4
        jsr     UI_PRINT
        lda     #<NAME_BUF
        sta     ZP_PTR
        lda     #>NAME_BUF
        sta     ZP_PTR+1
        ldx     #ROW_STAT
        ldy     #10
        jsr     UI_PRINT
        lda     #<STR_CONN
        sta     ZP_PTR
        lda     #>STR_CONN
        sta     ZP_PTR+1
        ldx     #ROW_PROMPT
        ldy     #4
        jsr     UI_PRINT
        ; ---- server
        jsr     NET_OPEN
        bne     @conn
        lda     #<STR_NOSRV
        sta     ZP_PTR
        lda     #>STR_NOSRV
        sta     ZP_PTR+1
        ldx     #ROW_PROMPT
        ldy     #4
        jsr     UI_PRINT
        lda     #ROW_PROMPT
        sta     UI_ROW
        lda     #22
        sta     UI_COL
        jsr     UI_BEGIN
        lda     MB_ERR
        jsr     UI_HEX2
        jsr     UI_END
        jsr     SES_PAUSE
        jmp     ses_local
@conn:  lda     #3
        sta     SES_STATE
        lda     #0
        sta     RX_WR
        sta     RX_RD
        sta     LOBBY_CNT
        sta     MENU_SEL
        sta     NET_ACTIVE
        lda     #$FF
        sta     MENU_PREV       ; a button held from power-on is no press
        ; ---- HELLO: [2+n][01][ver][name]
        lda     NAME_LEN
        clc
        adc     #2
        sta     TXBUF
        lda     #FT_HELLO
        sta     TXBUF+1
        lda     #PROTO_VER
        sta     TXBUF+2
        ldx     #0
:       lda     NAME_BUF,x
        sta     TXBUF+3,x
        inx
        cpx     NAME_LEN
        bne     :-
        txa
        clc
        adc     #3
        tax
        jsr     NET_WRITE
        jsr     SES_RENDER
        lda     #0
        sta     SES_TMR
        ; ---- lobby loop: one vblank, one pump per pass ------------------
@lobby: jsr     UI_WAITVBL
        jsr     SES_PUMP
        lda     NET_ACTIVE
        beq     :+
        jmp     @go
:       lda     NET_DROPPED     ; server went away under us
        beq     :+
        lda     #<STR_NOSRV
        ldx     #>STR_NOSRV
        jmp     ses_local_msg
:       jsr     SES_PAD
        cmp     MENU_PREV
        beq     @pace
        sta     MENU_PREV
        tay
        and     #$08            ; up
        bne     @up
        tya
        and     #$04            ; down
        bne     @dn
        tya
        and     #$90            ; A or Start
        bne     @join
        tya
        and     #$20            ; Select: play locally instead
        beq     @pace
        jsr     NET_CLOSE
        jmp     ses_local
@up:    lda     MENU_SEL
        beq     @rr
        dec     MENU_SEL
        jmp     @rr
@dn:    lda     MENU_SEL
        clc
        adc     #1
        cmp     LOBBY_CNT
        bcs     @rr
        sta     MENU_SEL
@rr:    jsr     SES_RENDER
        jmp     @pace
@join:  jsr     SES_JOIN
@pace:  inc     SES_TMR
        lda     SES_TMR
        cmp     #SES_LIST_FR
        bcc     @lobby
        lda     #0
        sta     SES_TMR
.if ::AUTO_JOIN
        lda     LOBBY_CNT
        beq     :+
        lda     #0
        sta     MENU_SEL
        jsr     SES_JOIN
:
.endif
        lda     #1              ; LIST
        sta     TXBUF
        lda     #FT_LIST
        sta     TXBUF+1
        ldx     #2
        jsr     NET_WRITE
        jmp     @lobby

        ; ---- matched ---------------------------------------------------
@go:    lda     #4
        sta     SES_STATE
        jsr     UI_BEGIN
        jsr     UI_CLS_RAW
        jsr     UI_END
        lda     #<STR_TITLE
        sta     ZP_PTR
        lda     #>STR_TITLE
        sta     ZP_PTR+1
        ldx     #ROW_TITLE
        ldy     #7
        jsr     UI_PRINT
        lda     #<STR_VS
        sta     ZP_PTR
        lda     #>STR_VS
        sta     ZP_PTR+1
        ldx     #7
        ldy     #8
        jsr     UI_PRINT
        lda     #<OPP_NAME
        sta     ZP_PTR
        lda     #>OPP_NAME
        sta     ZP_PTR+1
        ldx     #7
        ldy     #11
        jsr     UI_PRINT
        lda     NET_ROLE
        bne     @g2
        lda     #<STR_YOU1
        ldx     #>STR_YOU1
        jmp     @g3
@g2:    lda     #<STR_YOU2
        ldx     #>STR_YOU2
@g3:    sta     ZP_PTR
        stx     ZP_PTR+1
        ldx     #11
        ldy     #4
        jsr     UI_PRINT
        lda     #<STR_PAD1
        sta     ZP_PTR
        lda     #>STR_PAD1
        sta     ZP_PTR+1
        ldx     #14
        ldy     #4
        jsr     UI_PRINT
        lda     #<STR_MENUS
        sta     ZP_PTR
        lda     #>STR_MENUS
        sta     ZP_PTR+1
        ldx     #17
        ldy     #4
        jsr     UI_PRINT
        ; hold it up long enough to read, pumping: the peer may already be
        ; ticking and sending INPUT at us
        lda     #<SES_HOLD_FR
        sta     SES_TMR
        lda     #>SES_HOLD_FR
        sta     SES_TMR+1
@hold:  jsr     UI_WAITVBL
        jsr     SES_PUMP
        lda     SES_TMR
        bne     :+
        dec     SES_TMR+1
:       dec     SES_TMR
        lda     SES_TMR
        ora     SES_TMR+1
        bne     @hold
        lda     #5
        sta     SES_STATE
        lda     #1
        sta     NET_MODE
        rts
.endproc

; ses_local_msg -- A/X = notice; show it, pause, fall through to local.
.proc ses_local_msg
        sta     ZP_PTR
        stx     ZP_PTR+1
        ldx     #ROW_PROMPT
        ldy     #4
        jsr     UI_PRINT
        jsr     SES_PAUSE
.endproc
.proc ses_local
        lda     #0
        sta     NET_MODE
        sta     NET_ACTIVE
        lda     #6
        sta     SES_STATE
        rts
.endproc

; SES_PAUSE -- ~2 s.
.proc SES_PAUSE
        ldx     #120
:       jsr     UI_WAITVBL
        dex
        bne     :-
        rts
.endproc

; SES_PAD -- controller 1, read directly (the game's own reader would use
; its RAM). A = buttons in the game's bit order: A $80 B $40 Select $20
; Start $10 Up $08 Down $04 Left $02 Right $01.
.proc SES_PAD
        lda     #1
        sta     $4016
        lda     #0
        sta     $4016
        sta     ZP_TMP
        ldx     #8
:       lda     $4016
        and     #$03            ; standard pad or Famicom expansion pad
        cmp     #1
        rol     ZP_TMP
        dex
        bne     :-
        lda     ZP_TMP
        rts
.endproc

; SES_JOIN -- challenge the entry under the cursor.
.proc SES_JOIN
        lda     LOBBY_CNT
        beq     @out
        ; entry = LOBBY_CACHE + 1 + 9 * sel
        lda     MENU_SEL
        asl     a
        asl     a
        asl     a
        clc
        adc     MENU_SEL
        tax                     ; X = 9 * sel
        lda     LOBBY_CACHE+9,x ; the status byte after the name
        beq     @ok
        ; busy: the server would just drop it, which looks like a dead button
        lda     #<STR_BUSY
        sta     ZP_PTR
        lda     #>STR_BUSY
        sta     ZP_PTR+1
        ldx     #ROW_NOTE
        ldy     #4
        jmp     UI_PRINT
@ok:    lda     #9
        sta     TXBUF
        lda     #FT_JOIN
        sta     TXBUF+1
        ldy     #0
:       lda     LOBBY_CACHE+1,x
        sta     TXBUF+2,y
        inx
        iny
        cpy     #8
        bne     :-
        ldx     #10
        jsr     NET_WRITE
        lda     #<STR_JOINING
        sta     ZP_PTR
        lda     #>STR_JOINING
        sta     ZP_PTR+1
        ldx     #ROW_NOTE
        ldy     #4
        jmp     UI_PRINT
@out:   rts
.endproc

; ---------------------------------------------------------------------------
; SES_GETNAME -- Lobby username appkey (creator 1, app 1, key 0), one retry,
; 2-8 chars of A-Z0-9; else GUESTnn.
.proc SES_GETNAME
        lda     #2
        sta     LS_TMP
@try:   lda     #0
        jsr     AK_OPEN
        beq     @retry
        jsr     AK_READ
        beq     @retry
        ldx     FN_RPLY         ; length lo; hi ignored, clamp to 8
        lda     FN_RPLY+1
        beq     :+
        ldx     #8
:       cpx     #9
        bcc     :+
        ldx     #8
:       cpx     #2
        bcc     @bad
        stx     NAME_LEN
        ldy     #0
@c:     lda     FN_RPLY+2,y
        cmp     #'0'
        bcc     @bad
        cmp     #'9'+1
        bcc     @okc
        cmp     #'a'            ; Lobby names are often typed in lower case
        bcc     :+
        cmp     #'z'+1
        bcs     @bad
        and     #$DF
:       cmp     #'A'
        bcc     @bad
        cmp     #'Z'+1
        bcs     @bad
@okc:   sta     NAME_BUF,y
        iny
        dex
        bne     @c
        lda     #0
        sta     NAME_BUF,y
        jmp     AK_CLOSE
@bad:   jsr     AK_CLOSE
        jmp     @guest
@retry: jsr     AK_CLOSE
        dec     LS_TMP
        bne     @try
@guest: ldx     #0
:       lda     STR_GUEST,x
        sta     NAME_BUF,x
        inx
        cpx     #5
        bne     :-
        ; two digits: the cart's sequence counter is the one thing that
        ; differs between power-ons; rigs add a per-console build seed
        lda     FN_ACKS
        eor     #<GUEST_SEED
        pha
        and     #$0F
        jsr     @dig
        sta     NAME_BUF+5
        pla
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        jsr     @dig
        sta     NAME_BUF+6
        lda     #0
        sta     NAME_BUF+7
        lda     #7
        sta     NAME_LEN
        rts
@dig:   cmp     #10
        bcc     :+
        sbc     #10
:       ora     #'0'
        rts
.endproc

; ---------------------------------------------------------------------------
; SES_GETSERVER -- SRV_BUF = the devicespec to open. The NES Lobby hands a
; booted game its room's server URL through appkey creator 1 / app 1 /
; key GAME_APPKEY ("TCP://host:port/"); anything else -- no key, no SD
; card, not a TCP URL -- means the endpoint baked in at build time.
.proc SES_GETSERVER
        ldx     #0
:       lda     SRV_SPEC,x
        sta     SRV_BUF,x
        beq     :+
        inx
        bne     :-
:       lda     #GAME_APPKEY
        jsr     AK_OPEN
        beq     @close
        jsr     AK_READ
        beq     @close
        lda     FN_RPLY+1
        bne     @close          ; >= 256: not a URL we can use
        lda     FN_RPLY
        cmp     #8
        bcc     @close
        cmp     #SRV_BUF_LEN-3
        bcs     @close
        sta     ZP_T1
        ldx     #5              ; "TCP://", letters either case
:       lda     FN_RPLY+2,x
        cmp     #'a'
        bcc     :+
        and     #$DF
:       cmp     STR_TCP,x
        bne     @close
        dex
        bpl     :--
        lda     #'N'
        sta     SRV_BUF
        lda     #':'
        sta     SRV_BUF+1
        ldx     #0
:       lda     FN_RPLY+2,x
        sta     SRV_BUF+2,x
        inx
        cpx     ZP_T1
        bne     :-
        lda     #0
        sta     SRV_BUF+2,x
        lda     #1
        sta     SRV_LOBBY
@close: jmp     AK_CLOSE
.endproc

; ---------------------------------------------------------------------------
; SES_PUMP -- one STATUS, one bounded READ into the stream ring, then
; extract and dispatch every complete frame.
.proc SES_PUMP
        jsr     NET_STATUS
        lda     MB_OK
        beq     @parse
        lda     NAVAIL_HI
        bne     @cap
        lda     NAVAIL_LO
        beq     @parse
        cmp     #64
        bcc     @rd
@cap:   lda     #64
@rd:    sta     NREQ
        jsr     NET_READ
        ldx     NGOT
        beq     @parse
        ldy     #0
        ldx     RX_WR
:       lda     FN_RPLY,y
        sta     RXACC,x
        inx
        iny
        cpy     NGOT
        bne     :-
        stx     RX_WR
@parse:
        ; buffered = (wr - rd) & $FF
        lda     RX_WR
        sec
        sbc     RX_RD
        cmp     #2
        bcc     @done
        sta     ZP_T1           ; buffered
        ; ---- framing check. A bare length-prefixed stream: one byte lost
        ; or doubled misframes everything after it. Validate (type, len)
        ; against what the server can emit; on a mismatch drop one byte and
        ; rescan until the stream re-aligns.
        ldx     RX_RD
        lda     RXACC,x
        sta     ZP_T2           ; len (type + payload)
        inx
        lda     RXACC,x         ; type
        cmp     #$10
        bcs     @slip
        tay
        lda     FLEN_MIN,y
        beq     @slip           ; a type that never arrives inbound
        cmp     ZP_T2
        beq     :+
        bcs     @slip           ; len below this type's minimum
:       lda     ZP_T2
        cmp     FLEN_MAX,y
        beq     :+
        bcs     @slip           ; len above this type's maximum
:       ; complete?  need len + 1 bytes
        lda     ZP_T2
        cmp     ZP_T1
        bcs     @done
        ; extract len+1 bytes into FRMBUF
        ldx     RX_RD
        ldy     #0
:       lda     RXACC,x
        sta     FRMBUF,y
        inx
        iny
        cpy     ZP_T2
        bcc     :-
        beq     :-
        stx     RX_RD
        jsr     SES_ONFRAME
        jmp     @parse
@slip:  inc     RX_RD
        lda     DIAG_SLIP
        cmp     #$FF
        beq     @parse
        inc     DIAG_SLIP
        jmp     @parse
@done:  rts
.endproc

; ---------------------------------------------------------------------------
; SES_ONFRAME -- dispatch FRMBUF = [len][type][payload].
.proc SES_ONFRAME
        lda     FRMBUF+1
        cmp     #FT_INPUT
        beq     @input
        cmp     #FT_LOBBY
        bne     :+
        jmp     @lobby
:       cmp     #FT_START
        bne     :+
        jmp     @start
:       cmp     #FT_PEER_LEFT
        bne     :+
        jmp     @pl
:       cmp     #FT_CRC
        bne     :+
        jmp     RS_ON_CRC
:       cmp     #FT_STATE
        bne     :+
        jmp     RS_ON_STATE
:       cmp     #FT_RESYNC
        bne     :+
        jmp     RS_ON_REQ
:       rts                     ; PONG and friends
@input:
        ; tick_lo tick_hi in pad2. The watermark only moves forward: stale
        ; frames (pre-resync leftovers) are dropped.
        lda     NET_ACTIVE
        beq     @iold
        lda     FRMBUF+2
        sec
        sbc     RMT_WM_LO
        sta     ZP_T3
        lda     FRMBUF+3
        sbc     RMT_WM_HI
        bmi     @iold           ; behind the watermark
        bne     @inew
        lda     ZP_T3
        beq     @iold           ; equal: a duplicate
@inew:  ldx     FRMBUF+2
        lda     FRMBUF+4
        sta     RMT_RING,x
        lda     FRMBUF+2
        sta     RMT_WM_LO
        lda     FRMBUF+3
        sta     RMT_WM_HI
@iold:  rts
@lobby:
        lda     NET_ACTIVE
        bne     @lout
        ; count, then 9 bytes per entry; clamp to 8 and make sure the frame
        ; really carries that many
        lda     FRMBUF+2
        cmp     #9
        bcc     :+
        lda     #8
:       sta     ZP_T1
        asl     a
        asl     a
        asl     a
        clc
        adc     ZP_T1           ; 9 * count
        clc
        adc     #2
        cmp     FRMBUF
        beq     :+
        bcs     @lout
:       lda     ZP_T1
        sta     LOBBY_CNT
        sta     LOBBY_CACHE
        lda     MENU_SEL
        cmp     LOBBY_CNT
        bcc     :+
        lda     #0
        sta     MENU_SEL
:       ldx     #0
:       lda     FRMBUF+3,x
        sta     LOBBY_CACHE+1,x
        inx
        cpx     #72
        bne     :-
        jmp     SES_RENDER
@lout:  rts
@start:
        ; role seed_lo seed_hi delay opp[8]
        lda     FRMBUF+2
        and     #1
        sta     NET_ROLE
        lda     FRMBUF+3        ; the game's RNG starts from this (LS_START)
        sta     SEED_LO
        lda     FRMBUF+4
        sta     SEED_HI
        lda     FRMBUF+5
        bne     :+
        lda     #1
:       sta     NET_DELAY
        ldx     #0
:       lda     FRMBUF+6,x
        sta     OPP_NAME,x
        inx
        cpx     #8
        bne     :-
        lda     #0
        sta     OPP_NAME+8
        jsr     LS_START
        lda     #1
        sta     NET_ACTIVE
        rts
@pl:    lda     #1
        sta     PEER_WHY        ; the server saw the peer go, cleanly
        sta     NET_DROPPED
        jmp     LS_IDLE_RMT
.endproc

; ---------------------------------------------------------------------------
; SES_RENDER -- prompt, then the lobby rows from LOBBY_CACHE with a cursor.
.proc SES_RENDER
        jsr     UI_BEGIN
        lda     #ROW_PROMPT
        sta     UI_ROW
        lda     #4
        sta     UI_COL
        lda     #<STR_PICK
        sta     ZP_PTR
        lda     #>STR_PICK
        sta     ZP_PTR+1
        jsr     UI_PUTS
        lda     #0
        sta     ZP_T1           ; entry index
@row:   lda     ZP_T1
        asl     a
        clc
        adc     #ROW_LIST
        sta     UI_ROW
        lda     #2
        sta     UI_COL
        jsr     UI_AT
        lda     ZP_T1
        cmp     LOBBY_CNT
        bcs     @blank
        ; cursor, name, busy marker
        lda     #' '
        ldx     ZP_T1
        cpx     MENU_SEL
        bne     :+
        lda     #'>'
:       jsr     UI_CHR
        lda     #' '
        jsr     UI_CHR
        lda     ZP_T1
        asl     a
        asl     a
        asl     a
        clc
        adc     ZP_T1
        tax
        ldy     #8
:       lda     LOBBY_CACHE+1,x
        cmp     #$21
        bcs     :+
        lda     #' '
:       jsr     UI_CHR
        inx
        dey
        bne     :--
        lda     LOBBY_CACHE+1,x ; status
        beq     @idle
        ldx     #0
:       lda     STR_INGAME,x
        jsr     UI_CHR
        inx
        cpx     #10
        bne     :-
        jmp     @tail
@idle:  ldx     #10
        lda     #TILE_SPACE
:       sta     PPU_DATA
        dex
        bne     :-
        jmp     @tail
@blank: lda     #TILE_SPACE
        ldx     #20
:       sta     PPU_DATA
        dex
        bne     :-
@tail:  lda     #TILE_SPACE     ; to column 29: the pick prompt is
        ldx     #8              ;   wider than an entry
:       sta     PPU_DATA
        dex
        bne     :-
@next:  inc     ZP_T1
        lda     ZP_T1
        cmp     #8
        bcs     :+
        jmp     @row
:       ; an empty lobby says so
        lda     LOBBY_CNT
        bne     :+
        lda     #ROW_LIST
        sta     UI_ROW
        lda     #4
        sta     UI_COL
        lda     #<STR_EMPTY
        sta     ZP_PTR
        lda     #>STR_EMPTY
        sta     ZP_PTR+1
        jsr     UI_PUTS
:       jmp     UI_END
.endproc

; Inbound frame length bounds (len = type + payload), indexed by type.
; 0 = a type that only ever travels outbound. Mirror the server: LOBBY is
; capped at 8 entries (2 + 9*8), STATE is 3 (END) / 5 (BEGIN) / up to
; RS_CHUNK + 3.
FLEN_MIN:
        .byte   0, 0, 0, 2, 0, 13, 5, 5, 3, 3, 0, 1, 0, 1, 0, 0
FLEN_MAX:
        .byte   0, 0, 0, 74, 0, 13, 5, 5, RS_CHUNK+3, 3, 0, 1, 0, 1, 0, 0

        .include "srv_endpoint.inc"     ; SRV_SPEC, generated by the Makefile

STR_TCP:        .byte "TCP://"
; Only what the game's font has: A-Z, 0-9, space, ! : - and the chevrons
; (tools/mkfontmap.py). No full stops, slashes, brackets or equals signs.
STR_TITLE:      .byte "TECMO BOWL NETPLAY", 0
STR_NOFN:       .byte "NO FUJINET - LOCAL GAME ", 0
STR_NOSRV:      .byte "NO SERVER - LOCAL GAME", 0
STR_CONN:       .byte "CONNECTING", 0
STR_NAME:       .byte "NAME:", 0
STR_PICK:       .byte "A: PLAY   SELECT: SOLO GAME", 0
STR_EMPTY:      .byte "WAITING FOR PLAYERS", 0
STR_JOINING:    .byte "JOINING              ", 0
STR_BUSY:       .byte "ALREADY IN A GAME    ", 0
STR_INGAME:     .byte "  IN GAME "
STR_VS:         .byte "VS", 0
STR_YOU1:       .byte "YOU ARE 1UP - HOST", 0
STR_YOU2:       .byte "YOU ARE 2UP", 0
STR_PAD1:       .byte "PLAY ON CONTROLLER 1", 0
STR_MENUS:      .byte "1UP STARTS THE GAME", 0
STR_GUEST:      .byte "GUEST"
STR_GONE:       .byte "OPPONENT LEFT", 0
STR_LOST:       .byte "CONNECTION LOST", 0
STR_RESET:      .byte "PRESS RESET", 0
STR_DIAG:       .byte "SLIP REJ TMO ERR", 0
