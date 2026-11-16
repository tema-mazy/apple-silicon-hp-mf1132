# SPDX-License-Identifier: GPL-2.0-or-later
# eSCL scanner service for the HP LaserJet M1132 MFP on Linux.
# Debian: apt-get install build-essential pkg-config libusb-1.0-0-dev \
#         libmicrohttpd-dev libjpeg62-turbo-dev libpng-dev
PKGS    = libusb-1.0 libmicrohttpd libpng
CFLAGS ?= -O2 -Wall -Wextra -std=gnu11
CFLAGS += $(shell pkg-config --cflags $(PKGS)) -DHAVE_PNG
LDLIBS += $(shell pkg-config --libs $(PKGS)) -ljpeg -lpthread

all: m1132-escl

m1132-escl: m1132-escl.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f m1132-escl

.PHONY: all clean
