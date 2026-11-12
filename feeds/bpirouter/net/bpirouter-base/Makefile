# Maintainer: Ning <mimallaus@gmail.com>
include $(TOPDIR)/rules.mk

PKG_NAME:=bpirouter-base
PKG_VERSION:=1.0.0
PKG_RELEASE:=5

include $(INCLUDE_DIR)/package.mk

define Package/bpirouter-base
  SECTION:=net
  CATEGORY:=Network
  TITLE:=BpiRouter default configuration
  PKGARCH:=all
  DEPENDS:=+mwan3 +flock
endef

define Package/bpirouter-base/description
  Factory default settings for BpiRouter: hostname, timezone, WiFi, and LAN IP.
endef

define Build/Compile
endef

define Package/bpirouter-base/conffiles
/etc/config/bpirouter
endef

define Package/bpirouter-base/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/bpirouter $(1)/etc/config/bpirouter
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/11-bpirouter-mwan3-canonical $(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./files/etc/uci-defaults/12-bpirouter-sqm-canonical $(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./files/etc/uci-defaults/13-bpirouter-offload-disabled $(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-bpirouter-defaults $(1)/etc/uci-defaults/
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/bpirouter-factory-reset-button $(1)/usr/libexec/
	$(INSTALL_DATA) ./files/usr/libexec/bpirouter-mwan3-strict.awk $(1)/usr/libexec/
	$(INSTALL_DATA) ./files/usr/libexec/bpirouter-sqm-strict.awk $(1)/usr/libexec/
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_DATA) ./files/etc/banner $(1)/etc/banner.bpirouter
	$(INSTALL_DIR) $(1)/usr/share/nftables.d/ruleset-pre
	$(INSTALL_DATA) ./files/usr/share/nftables.d/ruleset-pre/90-bpirouter-s2s.nft $(1)/usr/share/nftables.d/ruleset-pre/
endef

$(eval $(call BuildPackage,bpirouter-base))
