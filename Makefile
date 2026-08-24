PROGNAME := cubicle

PREFIX   ?= /usr/local
BINDIR   ?= $(PREFIX)/bin
MANDIR   ?= $(PREFIX)/share/man
DOCDIR   ?= $(PREFIX)/share/doc/$(PROGNAME)
DESTDIR  ?=

INSTALL ?= install

.PHONY: install test

install:
	$(INSTALL) -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(MANDIR)/man1 $(DESTDIR)$(DOCDIR)
	$(INSTALL) -m 755 $(PROGNAME) $(DESTDIR)$(BINDIR)/$(PROGNAME)
	$(INSTALL) -m 644 $(PROGNAME).1 $(DESTDIR)$(MANDIR)/man1/$(PROGNAME).1
	$(INSTALL) -m 644 README.md $(DESTDIR)$(DOCDIR)/README.md

test:
	./tests/run.sh
