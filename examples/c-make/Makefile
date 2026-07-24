CC ?= cc
CFLAGS ?= -O2 -Wall
all: hello-make
hello-make: main.c
	$(CC) $(CFLAGS) $(CPPFLAGS) $(LDFLAGS) -o $@ $<
clean:
	rm -f hello-make
