# Tecmo Bowl (NES) -- FujiNet two-player netplay.
#
#   make                 the netplay ROM (build/tb_net.nes), SRV_HOST/SRV_PORT
#   make verify-org      split + rejoin of the original is byte-identical
#   make hook            HOOK build + patch audit + mailbox RMW audit
#   make run-hook        HOOK build in a MAME window: must feel like stock
#   make run-lag         SOLO build, controller 2 delayed 1 s: proof of capture
#   make det             determinism A/B: fuzz inputs; B adds stalls and a
#                        per-tick jitter; the per-tick checksums must match
#   make rig             2 x fujinet-pc + relay + 2 x MAME, auto-matched,
#                        fuzz inputs, CRC cross-check
#   make m4              desync injection -> detect -> push -> recover
#   make peerleft        opponent walks out, both notice-screen branches
#   make play            two playable consoles side by side on this machine
#                        (tools/play_local.sh: fujinet-pcs, relay, 2 MAMEs)
#   make lobby           the session screens against parked idle players
#   make profile         M0: the stock game's RAM map (build/profile.txt)
#   make server          run the relay in the foreground

SRV_HOST    ?= 127.0.0.1
SRV_PORT    ?= 9701
GAME_APPKEY ?= 41
ROM      := rom/tecmo_bowl.nes
BUILD    := build
CA65     ?= ca65
LD65     ?= ld65
PY       ?= python3

SRCS := src/bank8.s src/fix.s src/defs.inc src/vars.inc src/tb.cfg \
        src/ui/text.s src/ui/fontmap.inc src/netcode/mailbox.s \
        src/netcode/session.s src/netcode/lockstep.s src/netcode/resync.s \
        src/netcode/image.inc tools/patches.py tools/build_rom.py

.PHONY: all verify-org hook run-hook run-lag det rig m4 peerleft \
        server lobby play profile clean FORCE
all: $(BUILD)/tb_net.nes

$(BUILD):
	mkdir -p $@

# The text screens' character map comes from the game's own font.
src/ui/fontmap.inc emu/fontmap.lua: tools/mkfontmap.py $(ROM)
	$(PY) tools/mkfontmap.py $(ROM) src/ui/fontmap.inc emu/fontmap.lua

# The server endpoint is baked in; regenerate only when it changes.
$(BUILD)/srv_endpoint.inc: FORCE | $(BUILD)
	@printf 'SRV_SPEC:       .byte "N:TCP://%s:%s/", 0\n' "$(SRV_HOST)" "$(SRV_PORT)" > $@.tmp
	@cmp -s $@.tmp $@ || mv $@.tmp $@
	@rm -f $@.tmp
# Rig endpoints. Console 1's baked-in one is a dead port on purpose: its
# fujinet-pc carries the Lobby's server-URL appkey, so connecting at all
# proves that handoff. Console 2 runs on the build-time fallback.
$(BUILD)/rig_endpoint.inc: | $(BUILD)
	@printf 'SRV_SPEC:       .byte "N:TCP://127.0.0.1:%s/", 0\n' "$(RIG_PORT)" > $@
$(BUILD)/rig_dead_endpoint.inc: | $(BUILD)
	@printf 'SRV_SPEC:       .byte "N:TCP://127.0.0.1:9/", 0\n' > $@
FORCE:

RIG_PORT ?= 9799

# build/<name>.nes from the netcode assembled with that variant's flags
# $(call variant,name,flags,endpoint-dir)
define variant
$(BUILD)/$(1).bin: $(SRCS) $(BUILD)/srv_endpoint.inc $(BUILD)/rig_endpoint.inc $(BUILD)/rig_dead_endpoint.inc
	@mkdir -p $(BUILD)/$(1).d
	@cp $(3) $(BUILD)/$(1).d/srv_endpoint.inc
	$(CA65) -g -I src -I $(BUILD)/$(1).d -D GAME_APPKEY=$(GAME_APPKEY) $(2) -o $(BUILD)/$(1).o src/bank8.s
	$(LD65) -C src/tb.cfg -o $$@ -Ln $(BUILD)/$(1).lbl -m $(BUILD)/$(1).map $(BUILD)/$(1).o
$(BUILD)/$(1).nes: $(BUILD)/$(1).bin
	$(PY) tools/build_rom.py $(ROM) $$< $(BUILD)/$(1).lbl $$@
	$(PY) tools/check_patch.py $(ROM) $$@
	$(PY) tools/checkrom.py --claim --header-only $$@
	$(PY) tools/checkrom.py --raw 0x8000 $$<
endef

EP  := $(BUILD)/srv_endpoint.inc
REP := $(BUILD)/rig_endpoint.inc
DEP := $(BUILD)/rig_dead_endpoint.inc
$(eval $(call variant,tb_net,-D BUILD_KIND=1,$(EP)))
$(eval $(call variant,tb_hook,-D BUILD_KIND=0,$(EP)))
$(eval $(call variant,tb_lag,-D BUILD_KIND=2 -D SOLO_DELAY=60,$(EP)))
$(eval $(call variant,tb_fuzz,-D BUILD_KIND=2 -D FUZZ=1,$(EP)))
$(eval $(call variant,tb_detA,-D BUILD_KIND=2 -D FUZZ=1 -D TRACE=1,$(EP)))
$(eval $(call variant,tb_detB,-D BUILD_KIND=2 -D FUZZ=1 -D TRACE=1 -D STALL_N=9 -D JITTER=1,$(EP)))
$(eval $(call variant,tb_rig1,-D BUILD_KIND=1 -D FUZZ=1 -D GUEST_SEED=17,$(DEP)))
$(eval $(call variant,tb_rig2,-D BUILD_KIND=1 -D FUZZ=1 -D AUTO_JOIN=1 -D GUEST_SEED=34,$(REP)))

verify-org: | $(BUILD)
	$(PY) tools/build_rom.py --org $(ROM) $(BUILD)/org.nes
	cmp $(ROM) $(BUILD)/org.nes && echo "verify-org: OK"

hook: $(BUILD)/tb_hook.nes

run-hook: $(BUILD)/tb_hook.nes
	emu/run.sh $<

run-lag: $(BUILD)/tb_lag.nes
	emu/run.sh $<

det: $(BUILD)/tb_detA.nes $(BUILD)/tb_detB.nes
	test/run_det.sh

rig: $(BUILD)/tb_rig1.nes $(BUILD)/tb_rig2.nes
	RIG_PORT=$(RIG_PORT) GAME_APPKEY=$(GAME_APPKEY) test/run_rig.sh

m4: $(BUILD)/tb_rig1.nes $(BUILD)/tb_rig2.nes
	RIG_PORT=$(RIG_PORT) GAME_APPKEY=$(GAME_APPKEY) RIG_MODE=m4 test/run_rig.sh

peerleft: $(BUILD)/tb_rig1.nes $(BUILD)/tb_rig2.nes
	RIG_PORT=$(RIG_PORT) GAME_APPKEY=$(GAME_APPKEY) RIG_MODE=peerleft LEAVE_MODE=clean test/run_rig.sh
	RIG_PORT=$(RIG_PORT) GAME_APPKEY=$(GAME_APPKEY) RIG_MODE=peerleft LEAVE_MODE=timeout test/run_rig.sh

play:
	GAME_APPKEY=$(GAME_APPKEY) PLAY_PORT=$(SRV_PORT) tools/play_local.sh

lobby: $(BUILD)/tb_net.nes
	GAME_APPKEY=$(GAME_APPKEY) test/run_lobby.sh

profile: | $(BUILD)
	PROF_SECS=150 SECS=200 emu/run.sh $(ROM) profile > $(BUILD)/profile.txt

server:
	$(PY) server/tb_relay_server.py --port $(SRV_PORT)

clean:
	rm -rf $(BUILD)
