; vars.inc -- netcode state, all in the cart's WRAM ($6000-$7FFF).
;
; The STAT block sits at a fixed address ($6300) so the Lua test rigs can
; read it without a symbol file; keep its order stable and append only.

        .segment "RINGS"        ; $6000, page aligned
LOC_RING:       .res 256        ; our input, by tick & $FF
RMT_RING:       .res 256        ; the peer's input, by tick & $FF
RXACC:          .res 256        ; inbound byte stream, circular

        .segment "STAT"         ; $6300 -- rigs read these by address
NET_ACTIVE:     .res 1          ; +00 1 = lockstep armed
NET_ROLE:       .res 1          ; +01 0 = host (P1), 1 = guest (P2)
NET_DROPPED:    .res 1          ; +02 peer gone (either way)
PEER_WHY:       .res 1          ; +03 1 = server said so, 0 = we timed out
PEER_SCR:       .res 1          ; +04 peer-left screen is up
TICK_LO:        .res 1          ; +05 sim tick
TICK_HI:        .res 1          ; +06
DIAG_SLIP:      .res 1          ; +07 stream re-framings
DIAG_REJ:       .res 1          ; +08 refused state chunks
DIAG_TMO:       .res 1          ; +09 mailbox timeouts
DIAG_ERR:       .res 1          ; +0A error replies
RESYNC_HOLD:    .res 1          ; +0B sim frozen for a state push
RS_PEND:        .res 1          ; +0C a resync is wanted
HUD_LEAD:       .res 1          ; +0D min slack (remote WM - T) since last read
HUD_STL:        .res 1          ; +0E gate stall rounds (saturating)
HUD_RSY:        .res 1          ; +0F resyncs completed
HUD_HLD:        .res 1          ; +10 hold rounds (saturating)
RS_GATE:        .res 1          ; +11 last push: 1 quiescent, 2 at the cap
RS_WAITED:      .res 1          ; +12 ticks the last push waited
NET_DELAY:      .res 1          ; +13 d
RMT_WM_LO:      .res 1          ; +14 remote watermark
RMT_WM_HI:      .res 1          ; +15
CRC_LO:         .res 1          ; +16 last checksum
CRC_HI:         .res 1          ; +17
CRC_MIS:        .res 1          ; +18 CRC mismatches seen
NET_MODE:       .res 1          ; +19 0 local, 1 net, 2 solo (test builds)
SES_STATE:      .res 1          ; +1A session progress, for rigs
HUD_POLL:       .res 1          ; +1B mailbox polls / 256 (saturating)
LOCAL_IN:       .res 1          ; +1C last local input captured
; Tecmo Bowl additions. The NMI hooks in fix.s read and write these.
NMI_SEEN:       .res 1          ; +1D bumped by every NMI in net mode
IDLE:           .res 1          ; +1E the scheduler found nothing to run
TICK_DUE:       .res 1          ; +1F the tick NMI has done its display pass
CTRL_SH:        .res 1          ; +20 last MMC1 control value (mirroring)
CHR0_SH:        .res 1          ; +21 last MMC1 CHR0 bank
LAGN_LO:        .res 1          ; +22 lag NMIs (a task was running), 16 bits
LAGN_HI:        .res 1          ; +23

        .segment "BSS"
OWN_CRC:        .res 32         ; 8 records: tick_lo tick_hi crc_lo crc_hi
FRMBUF:         .res 128        ; one extracted frame: [len][type][payload]
TXBUF:          .res 128        ; outbound frame under construction
LOBBY_CACHE:    .res 73         ; count, then 8 x (name[8] status)
NAME_BUF:       .res 9
NAME_LEN:       .res 1
OPP_NAME:       .res 9
LOBBY_CNT:      .res 1
MENU_SEL:       .res 1
MENU_PREV:      .res 1
SES_TMR:        .res 2
RX_WR:          .res 1
RX_RD:          .res 1
MB_OK:          .res 1
MB_ERR:         .res 1
MB_TMO:         .res 1
MB_CNT:         .res 1
MB_SEQ:         .res 1
NAVAIL_LO:      .res 1
NAVAIL_HI:      .res 1
NGOT:           .res 1
NREQ:           .res 1
LS_WAITC_LO:    .res 1
LS_WAITC_HI:    .res 1
LS_TMP:         .res 1
FUZ_LO:         .res 1          ; test builds: per-console input fuzz
FUZ_HI:         .res 1
FUZ2_LO:        .res 1          ; solo builds: the other side's fuzz
FUZ2_HI:        .res 1
FUZ_CUR:        .res 4          ; [0] ours, [2] the SOLO peer's (stride 2,
                                ;   like FUZ_LO/HI and FUZ2_LO/HI)
STALL_CNT:      .res 1
RS_R_LO:        .res 1
RS_R_HI:        .res 1
RS_POS_LO:      .res 1
RS_POS_HI:      .res 1
RS_N:           .res 1
RS_PTMO:        .res 1
RS_TO_LO:       .res 1
RS_TO_HI:       .res 1
SRV_BUF_LEN = 80
SRV_BUF:        .res SRV_BUF_LEN ; the devicespec NET_OPEN uses
SRV_LOBBY:      .res 1          ; 1 = it came from the Lobby's appkey
ZP_SAVE:        .res ZP_LEN     ; the game's $F4-$F8 while we borrow them
ZP_T1:          .res 1          ; scratch (absolute: zero page is scarce)
ZP_T2:          .res 1
ZP_T3:          .res 1
SEED_LO:        .res 1          ; START's seed, for the game's RNG
SEED_HI:        .res 1
RD_PREV:        .res 1          ; LS_READ: last read, for the DPCM retry
RD_CUR:         .res 1
RD_LAST:        .res 1          ; LS_READ: the fallback after four misses
PAD2_LAST:      .res 1          ; SOLO: controller 2's last reading
POST_PEND:      .res 1          ; LS_TICK owes the last tick its epilogue
IN_TICK:        .res 1          ; inside LS_TICK: a resync may apply
RS_ENDP:        .res 1          ; END arrived outside a tick: apply later
IDLE_SEEN:      .res 1          ; NET_IDLE: frame of the last idle pump
CK_NEXT:        .res 1          ; next CRC part due (4 = complete, $FF = void)
TXIN:           .res 6          ; the INPUT frame for T+d, sent from idle
TXIN_PEND:      .res 1
JIT_LO:         .res 1          ; det B: per-tick jitter stream
JIT_HI:         .res 1
UI_ROW:         .res 1
UI_COL:         .res 1
UI_X:           .res 1
HEXBUF:         .res 3

        .segment "IMG"          ; resync image staging, see resync.s
IMG_BUF:        .res IMG_TOTAL

        .segment "TRACE"        ; test builds: per-tick checksum trace
TRACE_BUF:      .res 2048       ; 1024 ticks x (lo, hi)
