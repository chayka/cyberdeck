# Out-of-tree build for the UPS HAT (E) power_supply driver.
#
#   make            build against the running kernel
#   make clean
#   sudo make install   (prefer install-driver.sh, which routes through DKMS)

obj-m += ups-hat-e.o

KVERSION ?= $(shell uname -r)
KDIR     ?= /lib/modules/$(KVERSION)/build
PWD      := $(CURDIR)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install: all
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a $(KVERSION)

.PHONY: all clean install
