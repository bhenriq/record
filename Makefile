CFLAGS  = -Wall -Wextra -Os -g
LDFLAGS = -framework CoreAudio -framework AudioToolbox -framework Foundation
CC      = cc

capture: capture.m
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f capture
