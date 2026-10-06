; text.s -- a text screen for the session and the peer-left notice.
;
; Our screens run with NMI off and own the PPU outright. Tecmo Bowl's CHR is
; ROM, so there is no font to upload: CHR1 is pointed at the 4K bank that
; holds the game's own (FONT_BANK), the background is taken from $1000, and
; every character goes through FONTMAP (tools/mkfontmap.py) on its way to
; the nametable. The game reselects CHR1 at its first NMI, and UI_WIPE
; scrubs the nametables and palette before handing over.
;
; Writes happen with rendering off (UI_BEGIN ... UI_END). A redraw therefore
; blanks one frame; at lobby refresh rates nobody minds.

TILE_SPACE      = $20

; UI_OFF -- NMI and rendering off, now.
.proc UI_OFF
        lda     #0
        sta     PPU_CTRL
        sta     PPU_MASK
        rts
.endproc

; UI_WAITVBL -- wait for the next vblank (NMI is off, so poll).
.proc UI_WAITVBL
        bit     PPU_STATUS
:       bit     PPU_STATUS
        bpl     :-
        rts
.endproc

; UI_INIT -- font bank, palette, blank nametable; leaves the screen off.
.proc UI_INIT
        jsr     UI_OFF
        jsr     UI_WAITVBL
        lda     #FONT_BANK      ; NMI is off: the serial write is ours alone
        jsr     G_CHR1SW
        ; palette: black, and the font's colours all white
        lda     #$3F
        sta     PPU_ADDR
        lda     #$00
        sta     PPU_ADDR
        ldx     #8
:       lda     #$0F
        sta     PPU_DATA
        lda     #$30
        sta     PPU_DATA
        sta     PPU_DATA
        sta     PPU_DATA
        dex
        bne     :-
        jmp     UI_CLS_RAW
.endproc

; UI_CLS_RAW -- nametable 0 to spaces, attributes 0. Screen must be off.
.proc UI_CLS_RAW
        lda     #$20
        sta     PPU_ADDR
        lda     #$00
        sta     PPU_ADDR
        lda     #TILE_SPACE
        ldy     #3              ; 960 tiles = 3 x 256 + 192
        ldx     #0
@p:     sta     PPU_DATA
        inx
        bne     @p
        dey
        bne     @p
        ldx     #192
@r:     sta     PPU_DATA
        dex
        bne     @r
        lda     #0              ; attributes
        ldx     #64
:       sta     PPU_DATA
        dex
        bne     :-
        rts
.endproc

; UI_BEGIN / UI_END -- bracket nametable writes.
.proc UI_BEGIN
        jsr     UI_WAITVBL
        lda     #0
        sta     PPU_MASK
        rts
.endproc

.proc UI_END
        jsr     UI_WAITVBL
        lda     #%00010000      ; BG from $1000 (CHR1: the font), NMI off
        sta     PPU_CTRL
        lda     #0
        sta     PPU_SCROLL
        sta     PPU_SCROLL
        lda     #%00001010      ; BG on, leftmost column too
        sta     PPU_MASK
        rts
.endproc

; UI_CLS -- blank the visible screen.
.proc UI_CLS
        jsr     UI_BEGIN
        jsr     UI_CLS_RAW
        jmp     UI_END
.endproc

; UI_AT -- set the PPU address to row UI_ROW, column UI_COL of nametable 0.
.proc UI_AT
        lda     UI_ROW
        lsr     a
        lsr     a
        lsr     a
        ora     #$20
        sta     PPU_ADDR
        lda     UI_ROW
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a
        ora     UI_COL
        sta     PPU_ADDR
        rts
.endproc

; UI_CHR -- A = an ASCII character, drawn at the PPU address; anything the
; font lacks is a space. Keeps X and Y.
.proc UI_CHR
        sec
        sbc     #$20
        bcc     @sp
        cmp     #$60
        bcs     @sp
        stx     UI_X
        tax
        lda     FONTMAP,x
        ldx     UI_X
        sta     PPU_DATA
        rts
@sp:    lda     #TILE_SPACE
        sta     PPU_DATA
        rts
.endproc

; UI_PUTS -- NUL-terminated string at ZP_PTR to (UI_ROW, UI_COL). Inside a
; UI_BEGIN/UI_END bracket.
.proc UI_PUTS
        jsr     UI_AT
        ldy     #0
:       lda     (ZP_PTR),y
        beq     @done
        jsr     UI_CHR
        iny
        bne     :-
@done:  rts
.endproc

; UI_HEX2 -- A as two hex digits at (UI_ROW, UI_COL).
.proc UI_HEX2
        pha
        jsr     UI_AT
        pla
        pha
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        jsr     @dig
        pla
        and     #$0F
@dig:   cmp     #10
        bcc     :+
        adc     #'A'-'0'-10-1
:       adc     #'0'
        jmp     UI_CHR
.endproc

; UI_PRINT -- convenience: X = row, Y = column, ZP_PTR = string; one
; bracketed write.
.proc UI_PRINT
        stx     UI_ROW
        sty     UI_COL
        jsr     UI_BEGIN
        jsr     UI_PUTS
        jmp     UI_END
.endproc

; UI_WIPE -- before the game gets the PPU back: both nametables and the
; palette to zero, the scroll home. Screen off, NMI off. (No CHR: it is ROM.)
.proc UI_WIPE
        jsr     UI_WAITVBL
        lda     #$20
        sta     PPU_ADDR
        lda     #$00
        sta     PPU_ADDR
        tax
        ldy     #8              ; $2000-$27FF
:       sta     PPU_DATA
        inx
        bne     :-
        dey
        bne     :-
        lda     #$3F
        sta     PPU_ADDR
        lda     #$00
        sta     PPU_ADDR
        lda     #$0F
        ldx     #32
:       sta     PPU_DATA
        dex
        bne     :-
        lda     #0
        sta     PPU_SCROLL
        sta     PPU_SCROLL
        rts
.endproc

        .segment "RODATA"
        .include "ui/fontmap.inc"
        .segment "CODE"
