obj-m += fake_battery_nut.o

KERN_VER=$(shell uname -r)

all:
	make -C /lib/modules/$(KERN_VER)/build M=$(shell pwd) modules

clean:
	rm -f *.cmd *.ko *.o Module.symvers modules.order *.mod.c *.mod

install:
	install -D -m 644 fake_battery_nut.ko /lib/modules/$(KERN_VER)/extra/fake_battery_nut.ko
	depmod -a

uninstall:
	rm -f /lib/modules/$(KERN_VER)/extra/fake_battery_nut.ko
	depmod -a
