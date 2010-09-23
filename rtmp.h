#ifndef VIDEOAPI_RTMP_H
#define VIDEOAPI_RTMP_H

#include <stdint.h>
#include <ev.h>

#define MKTAG(a, b, c, d) ((a) | ((b) << 8) | ((c) << 16) | ((d) << 24))

#define RTMPERR(error) -error
#define INVALIDDATA MKTAG('I','N','V','L')

// emulated things
#define FMS_VER_MAJOR 3
#define FMS_VER_MINOR 5
#define FMS_VER_MICRO 1
#define FMS_VER_NANO  1

// 3 (chunk header) + 11 (header) + 4 (extended timestamp) = 18
#define RTMP_MAX_HEADER_SIZE 18
#define RTMP_CHANNELS 65600
#define RTMP_DEFAULT_CHUNKSIZE 128

// size in bytes
typedef enum chunk_sizes { CHUNK_SIZE_LARGE  = 11,
                   CHUNK_SIZE_MEDIUM =  7,
                   CHUNK_SIZE_SMALL  =  3,
                   CHUNK_SIZE_TINY   =  0
}chunk_sizes;

typedef enum chunk_types { CHUNK_LARGE = 0,
                           CHUNK_MEDIUM,
                           CHUNK_SMALL,
                           CHUNK_TINY
}chunk_types;

typedef enum rtmp_state { UNINIT = 0,
                          HANDSHAKE,
                          READ
}rtmp_state;

typedef struct rtmp_packet {
    int chunk_id;
    int msg_id; // useless?
    int msg_type;
    int size;
    int read;
    uint32_t timestamp;
    chunk_types chunk_type;
    uint8_t *body;
 }rtmp_packet;

typedef struct rtmp {
    int fd;
    int off; // handshake offset. When off == 0, signals pre-FP9 cxns
    int chunk_size; // max 65546 bytes
    uint32_t rx;
    uint32_t tx;
    rtmp_state state;

    // write buffer
    uint8_t write_buf[1600];
    int bytes_waiting;

    rtmp_packet *in_channels[RTMP_CHANNELS]; // find a better way
    rtmp_packet *out_channels[RTMP_CHANNELS];
    ev_io read_watcher;
    void (*read_cb)(struct rtmp *r, rtmp_packet *pkt, void *opaque);
}rtmp;

void rtmp_parser_init(rtmp *r);
void rtmp_init(rtmp *r);
void rtmp_free(rtmp *r);
void rtmp_read(struct ev_loop *loop, ev_io *io, int revents);
int  rtmp_send(rtmp *r, struct rtmp_packet *pkt);
void CalculateDigest(unsigned int digestPos, uint8_t *handshakeMessage,
		        const uint8_t *key, size_t keyLen, uint8_t *digest);

#endif
