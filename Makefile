################################################################################
# Makefile - Makefile for installing the 389 Directory Server Backup script
################################################################################
#
# Copyright (C) 2019 Adfinis SyGroup AG
#                    https://adfinis-sygroup.ch
#                    info@adfinis-sygroup.ch
#
# This program is free software: you can redistribute it and/or
# modify it under the terms of the GNU Affero General Public 
# License as published  by the Free Software Foundation, version
# 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public
# License  along with this program.
# If not, see <http://www.gnu.org/licenses/>.
#
# Please submit enhancements, bugfixes or comments via:
# https://github.com/adfinis-sygroup/389-directory-backup
#
# Authors:
#  Christian Affolter <christian.affolter@adfinis-sygroup.ch>

PN = 389-directory-backup

# Standard commands according to
# https://www.gnu.org/software/make/manual/html_node/Makefile-Conventions.html
SHELL = /bin/sh
INSTALL = /usr/bin/install
INSTALL_PROGRAM = $(INSTALL)
INSTALL_DATA = $(INSTALL) -m 644

# Standard directories according to
# https://www.gnu.org/software/make/manual/html_node/Directory-Variables.html#Directory-Variables
prefix = /usr/local
exec_prefix = $(prefix)
bindir = $(exec_prefix)/bin
datarootdir = $(prefix)/share
datadir = $(datarootdir)
docrootdir = $(datarootdir)/doc
docdir = $(docrootdir)/$(PN)
sbindir = $(exec_prefix)/sbin
sysconfdir = $(prefix)/etc
libdir = $(exec_prefix)/lib
libexecdir = $(exec_prefix)/libexec
localstatedir = $(prefix)/var
runstatedir = $(localstatedir)/run

# Systemd paths
systemddir = $(libdir)/systemd
systemdunitdir = $(systemddir)/system


.PHONY: all
all: 389-directory-backup systemd-units


.PHONY: 389-directory-backup
389-directory-backup:
	sed -e 's|^\(confDir\)=.*|\1=$(sysconfdir)|' \
		bin/$(PN).sh > \
		bin/$(PN).sh.tmp


.PHONY: systemd-units
systemd-units:
	sed \
		-e 's|/usr/local/bin|$(bindir)|' \
		-e 's|/usr/local/etc|$(sysconfdir)|' \
		systemd/$(PN)@.service > systemd/$(PN)@.service.tmp
	
	sed \
		-e 's|/usr/local/var|$(localstatedir)|' \
		-e 's|/usr/local/etc|$(sysconfdir)|' \
		systemd/$(PN)-env.conf > systemd/$(PN)-env.conf.tmp


.PHONY: installdirs
installdirs:
	$(INSTALL) --directory \
		$(DESTDIR)$(bindir) \
		$(DESTDIR)$(sysconfdir) \
		$(DESTDIR)$(docdir) \
		$(DESTDIR)$(systemdunitdir)


.PHONY: install
install: all installdirs
	$(INSTALL_PROGRAM) bin/$(PN).sh.tmp \
		$(DESTDIR)$(bindir)/$(PN).sh
	
	$(INSTALL_DATA) systemd/$(PN)@.service.tmp \
		$(DESTDIR)$(systemdunitdir)/$(PN)@.service
	
	$(INSTALL_DATA) systemd/$(PN)-env.conf.tmp \
		$(DESTDIR)$(sysconfdir)/$(PN)-env.conf
	
	$(INSTALL_DATA) systemd/$(PN)@.timer $(DESTDIR)$(systemdunitdir)/
		
	$(INSTALL_DATA) README.md $(DESTDIR)$(docdir)/


.PHONY: uninstall
uninstall:
	rm --force \
		$(DESTDIR)$(bindir)/$(PN).sh \
		$(DESTDIR)$(datadir)/$(PN)/* \
		$(DESTDIR)$(systemdunitdir)/$(PN)@.service \
		$(DESTDIR)$(sysconfdir)/$(PN)-env.conf \
		$(DESTDIR)$(systemdunitdir)/$(PN)@.timer \
		$(DESTDIR)$(docdir)/README.md
	
	rmdir --ignore-fail-on-non-empty \
		$(DESTDIR)$(bindir) \
		$(DESTDIR)$(docdir) \
		$(DESTDIR)$(docrootdir) \
		$(DESTDIR)$(sysconfdir) \
		$(DESTDIR)$(systemdunitdir) \
		$(DESTDIR)$(systemddir) \
		$(DESTDIR)$(datarootdir) \
		$(DESTDIR)$(libdir) \
		$(DESTDIR)$(exec_prefix)
	
# Usually $(prefix) is equal to $(exec_prefix) which was already
# removed, test for the directory existence to prevent errors.
	test -d $(DESTDIR)$(prefix) && \
		rmdir --ignore-fail-on-non-empty $(DESTDIR)$(exec_prefix) || \
			true

.PHONY: clean
clean:
	rm --force bin/$(PN).sh.tmp systemd/*.tmp
