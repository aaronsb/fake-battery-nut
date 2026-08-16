# Read by kbuild, and shipped into /usr/src/<pkg>-<ver>/ for DKMS to build from.
# dkms.conf's MAKE[0] invokes kbuild with M=<that directory>, and kbuild looks
# for Kbuild before Makefile — which is what leaves the repository's Makefile
# free for developer and packaging targets that have no business in /usr/src.

obj-m += fake_battery_nut.o
