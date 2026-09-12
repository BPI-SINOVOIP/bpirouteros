# Maintainer: Ning <mimallaus@gmail.com>
include $(TOPDIR)/rules.mk

PKG_NAME:=bpirouter-ui
# Formal builds export the APK-compatible version derived from their immutable
# release ID (v1.5.0-rc2 -> 1.5.0_rc2).  An unbound developer build is labelled
# explicitly as such instead of impersonating a product release.
PKG_VERSION:=$(if $(BPIROUTER_UI_PKG_VERSION),$(BPIROUTER_UI_PKG_VERSION),0.0.0_pre)
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

RSTRIP:=:
STRIP:=:

define Package/bpirouter-ui
  SECTION:=net
  CATEGORY:=Network
  TITLE:=BpiRouter Web Management UI
# sqm-scripts is a product-wide backend capability. mwan3 remains selected by
# the six board configs so its documented not-installed degradation stays
# testable. EC200A-AU is a six-board USB Dongle candidate, including OpenWrt
# One: own the option tty driver here instead of receiving it only by accident
# through comgt-ncm on the five boards with modem slots.
#
# The backend no longer runs gcom at all -- every AT exchange, PIN entry
# included, goes through its own single long-lived owner of the tty
# (internal/atserial). comgt is kept here because netifd's NCM proto path still
# needs it: comgt-ncm ships /lib/netifd/proto/ncm.sh and is selected by the five
# boards with modem slots, while OpenWrt One (no slot, USB dongle only) selects
# neither. Dropping this dependency is a separate change that has to be proven
# per board against a real dial, not folded into the AT-ownership work.
  DEPENDS:=+nginx-ssl +nginx-ssl-util +openssl-util +wireguard-tools +qrencode +jsonfilter +openvpn-openssl +uboot-envtools +lsblk +ddns-scripts +ddns-scripts-noip +ddns-scripts-cloudflare +sqm-scripts +comgt +kmod-usb-serial-option
endef

define Package/bpirouter-ui/description
  Modern web management interface for BpiRouter industrial routers.
  Vue 3 + Naive UI frontend with Go JSON-RPC backend.
endef

define Build/Compile
endef

define Package/bpirouter-ui/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/bpirouter-apid $(1)/usr/bin/
	$(INSTALL_BIN) ./files/bpirouter-gen-cert $(1)/usr/bin/
	$(INSTALL_BIN) ./files/bpirouter-reboot-handoff $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/libexec/bpirouter-reboot-worker $(1)/usr/libexec/
	$(INSTALL_BIN) ./files/libexec/bpirouter-ota-restore $(1)/usr/libexec/
# Provenance, written by bpirouter-ui/deploy/build.sh. Without it the only way
# to tell which source an image carries is to call RPCs and see which ones are
# missing. Fails the build when absent rather than shipping an image that
# cannot say what it is.
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_DATA) ./files/version $(1)/etc/bpirouter-version
	$(INSTALL_DATA) ./files/.manifest $(1)/etc/bpirouter-ui-build.manifest
	$(INSTALL_DATA) ./files/.payload-inventory $(1)/etc/bpirouter-product-payload.manifest
	$(INSTALL_DIR) $(1)/www/bpirouter
	$(CP) ./files/www/* $(1)/www/bpirouter/
	$(INSTALL_DIR) $(1)/usr/share/bpirouter/nginx
	$(INSTALL_DATA) ./files/nginx/bpirouter.conf $(1)/usr/share/bpirouter/nginx/
	$(INSTALL_DATA) ./files/nginx/bpirouter-locations.inc $(1)/usr/share/bpirouter/nginx/
	$(INSTALL_DIR) $(1)/etc/nginx
	$(INSTALL_DATA) ./files/nginx/nginx.conf $(1)/etc/nginx/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/init.d/bpirouter-api $(1)/etc/init.d/
	$(INSTALL_BIN) ./files/init.d/bpirouter-cfg-recovery $(1)/etc/init.d/
	$(INSTALL_BIN) ./files/init.d/bpirouter-ota-restore $(1)/etc/init.d/
	$(INSTALL_BIN) ./files/init.d/bpirouter-bootok $(1)/etc/init.d/
	$(INSTALL_BIN) ./files/init.d/bpirouter-reboot-worker $(1)/etc/init.d/
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/uci-defaults/99-bpirouter-setup $(1)/etc/uci-defaults/
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/keep.d/bpirouter-ui $(1)/lib/upgrade/keep.d/bpirouter-ui
	$(INSTALL_DIR) $(1)/usr/share/bpirouter/acceptance/lib
	$(INSTALL_BIN) ./files/acceptance/seg-acceptance.sh $(1)/usr/share/bpirouter/acceptance/
	$(INSTALL_BIN) ./files/acceptance/tel-acceptance.sh $(1)/usr/share/bpirouter/acceptance/
	$(INSTALL_BIN) ./files/acceptance/cell-acceptance.sh $(1)/usr/share/bpirouter/acceptance/
	$(INSTALL_BIN) ./files/acceptance/qos-acceptance.sh $(1)/usr/share/bpirouter/acceptance/
	$(INSTALL_BIN) ./files/acceptance/lib/acceptance-common.sh $(1)/usr/share/bpirouter/acceptance/lib/
endef

define Package/bpirouter-ui/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/uci-defaults/99-bpirouter-setup
	rm -f /etc/uci-defaults/99-bpirouter-setup
}
endef

$(eval $(call BuildPackage,bpirouter-ui))
