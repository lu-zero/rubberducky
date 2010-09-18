
PKGCFG_DEPS=librtmp openssl
DEPS=-lev `pkg-config --cflags --libs $(PKGCFG_DEPS)`
OPTS=-g
CC=gcc

default:
	ragel rtmp.rl
	$(CC) $(OPTS) $(DEPS) mediaserver.c process_messages.c rtmp.c rtmpfuncs.c
dot:
	ragel -V rtmp.rl > rtmp.dot
	dot rtmp.dot -Tps > rtmp.ps

