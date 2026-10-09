DESTDIR=
PREFIX=/usr
PERLDIR=$(PREFIX)/share/perl5

# see src/Makefile
PVE_INIT_SYSTEM ?= systemd

SOURCES=Agent.pm	\
	Blockdev.pm	\
	BlockJob.pm	\
	BuildConfig.pm	\
	Cfg2Cmd.pm	\
	CGroup.pm	\
	Cloudinit.pm	\
	CPUConfig.pm	\
	CPUFlags.pm	\
	DBusVMState.pm	\
	Drive.pm	\
	DriveDevice.pm	\
	Helpers.pm	\
	ImportDisk.pm	\
	Machine.pm	\
	Memory.pm	\
	MetaInfo.pm	\
	Monitor.pm	\
	Network.pm	\
	OVMF.pm		\
	PCI.pm		\
	QemuImage.pm	\
	QMPHelpers.pm	\
	QSD.pm		\
	RNG.pm		\
	RunState.pm	\
	StateFile.pm	\
	USB.pm		\
	Virtiofs.pm	\
	VolumeChain.pm

.PHONY: install
install: $(SOURCES)
	for i in $(SOURCES); do install -D -m 0644 $$i $(DESTDIR)$(PERLDIR)/PVE/QemuServer/$$i; done
	$(MAKE) -C Cfg2Cmd install
	$(MAKE) -C PCI install

# Generated according to PVE_INIT_SYSTEM. FORCE, as the content depends on a
# variable, not on the template's mtime: switching PVE_INIT_SYSTEM between
# builds would keep a stale BuildConfig.pm otherwise.
BuildConfig.pm: BuildConfig.pm.in FORCE
	sed -e 's/@INIT_SYSTEM_LSBSERVICE@/$(if $(filter lsbservice,$(PVE_INIT_SYSTEM)),1,0)/' $< > $@

.PHONY: FORCE
FORCE:

.PHONY: clean
clean:
	rm -f BuildConfig.pm
