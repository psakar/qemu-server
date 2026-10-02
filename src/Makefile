all:

# Which init system the services are integrated with: 'systemd' installs the
# systemd units, 'lsbservice' none - debian/rules installs LSB init scripts
# instead then. Set by debian/rules depending on whether the
# pkg.qemu-server.lsbservice build profile is active.
export PVE_INIT_SYSTEM ?= systemd
ifeq ($(filter $(PVE_INIT_SYSTEM),systemd lsbservice),)
$(error unsupported PVE_INIT_SYSTEM '$(PVE_INIT_SYSTEM)' (expected 'systemd' or 'lsbservice'))
endif

.PHONY: install
install:
	$(MAKE) -C PVE install
	$(MAKE) -C bin install
	$(MAKE) -C qmeventd install
	$(MAKE) -C query-machine-capabilities install
	$(MAKE) -C usr install

.PHONY: test
test:
	$(MAKE) -C test
	$(MAKE) -C bin $@

.PHONY: clean
clean:
	$(MAKE) -C test $@
	$(MAKE) -C bin $@

.PHONY: distclean
distclean: clean
