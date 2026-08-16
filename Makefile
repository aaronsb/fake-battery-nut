# Developer and packaging targets. The module itself is built by kbuild from
# Kbuild, which is what gets shipped into /usr/src for DKMS — this file is not
# installed anywhere.
#
# arch-repo publishes this package. It reads ./PKGBUILD from the default branch,
# takes the version and checksum from the newest published release, builds in a
# clean container, lints, signs, and pushes to the AUR and the [aaronsb] pacman
# repository. There is deliberately no aur target, and publish-aur.sh is gone
# with it: a second writer to one AUR ref is how a PKGBUILD and its .SRCINFO
# drift apart.

NAME    := $(shell sed -n 's/^pkgname=//p' PKGBUILD)
SRCNAME := $(or $(shell sed -n 's/^_repo=//p' PKGBUILD),$(NAME))

# dkms.conf is where this project's version actually lives. It ships inside the
# tarball and DKMS requires it to match the directory it is unpacked into, so it
# is the value a release has to move. PKGBUILD's pkgver is a placeholder
# arch-repo overwrites.
VERSION  := $(shell sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' dkms.conf)
KERN_VER ?= $(shell uname -r)

.PHONY: help all clean install uninstall check package version

help: ## List targets
	@grep -hE '^[a-z][a-z-]*:.*##' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | expand -t20

all: ## Build the module against the running kernel
	$(MAKE) -C /lib/modules/$(KERN_VER)/build M=$(CURDIR) modules

clean: ## Remove module build output
	rm -f *.cmd *.ko *.o Module.symvers modules.order *.mod.c *.mod
	rm -rf pkgbuild-check

install: ## Install the built module into the running kernel
	install -D -m 644 fake_battery_nut.ko /lib/modules/$(KERN_VER)/extra/fake_battery_nut.ko
	depmod -a

uninstall: ## Remove the installed module
	rm -f /lib/modules/$(KERN_VER)/extra/fake_battery_nut.ko
	depmod -a

check: version all ## Everything CI would run

# Reporting rather than failing: before a release the tag is legitimately
# absent, and after one it is legitimately present, so neither is an error.
version: ## Report the version this repository would release
	@test -n "$(VERSION)" || { echo "no PACKAGE_VERSION in dkms.conf" >&2; exit 1; }
	@if git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null; then \
	    echo "$(NAME) $(VERSION) — v$(VERSION) is already tagged"; \
	else \
	    echo "$(NAME) $(VERSION) — not yet tagged; this is what the next release will be"; \
	fi

package: version ## Build ./PKGBUILD in a clean chroot and namcap it
	@command -v extra-x86_64-build >/dev/null || { echo "needs devtools" >&2; exit 1; }
	@command -v namcap >/dev/null            || { echo "needs namcap" >&2; exit 1; }
	rm -rf pkgbuild-check && mkdir -p pkgbuild-check
	# The tarball the release would carry, built from HEAD and named exactly
	# what source= resolves to, so makepkg uses it instead of fetching
	# archive/v$$pkgver.tar.gz — which GitHub does not generate until the tag
	# exists. A dry run that needs the release to have happened is not one.
	#
	# HEAD, not the working tree: a release ships a commit. Uncommitted changes
	# are not in the archive, and a file you have only just added will be
	# missing from the build rather than silently included.
	git archive --format=tar.gz --prefix=$(SRCNAME)-$(VERSION)/ \
	    -o pkgbuild-check/$(NAME)-$(VERSION).tar.gz HEAD
	cp PKGBUILD $(wildcard *.install) pkgbuild-check/
	# Slot one only, which is the entry that moves with the version and the one
	# arch-repo writes. The sums array is the only quoted 64-hex in a recipe.
	cd pkgbuild-check \
	  && sed -i 's/^pkgver=.*/pkgver=$(VERSION)/' PKGBUILD \
	  && sum=$$(sha256sum $(NAME)-$(VERSION).tar.gz | cut -d' ' -f1) \
	  && sed -i "0,/'[0-9a-f]\{64\}'/s//'$$sum'/" PKGBUILD
	cd pkgbuild-check && extra-x86_64-build
	# namcap exits 0 whether or not it found errors, so its output decides —
	# the same rule arch-repo's gate uses.
	cd pkgbuild-check && namcap PKGBUILD $$(ls ./*.pkg.tar.zst | grep -v -- '-debug-') | tee namcap.txt
	@cd pkgbuild-check && if [ -f ../.namcap-allow ]; then \
	    bad=$$(grep ' E: ' namcap.txt | grep -vE -f ../.namcap-allow || true); \
	  else \
	    bad=$$(grep ' E: ' namcap.txt || true); \
	  fi; \
	  if [ -n "$$bad" ]; then echo "namcap errors:"; printf '%s\n' "$$bad"; exit 1; fi; \
	  echo "namcap: no errors"
