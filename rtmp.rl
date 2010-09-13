/* system includes */
#include <stdio.h>
#include <string.h>
#include <stddef.h>
#include <netinet/in.h>
#include <assert.h>

/* these are primarily for get_uptime */
#include <stdint.h>
#include <sys/times.h>
#include <unistd.h>

#include <openssl/sha.h>
#include <openssl/hmac.h>

#if OPENSSL_VERSION_NUMBER < 0x0090800 || !defined(SHA256_DIGEST_LENGTH)
#error Your OpenSSL is too old, need 0.9.8 or newer with SHA256
#endif
#define HMAC_setup(ctx, key, len)	HMAC_CTX_init(&ctx); HMAC_Init_ex(&ctx, key, len, EVP_sha256(), 0)
#define HMAC_crunch(ctx, buf, len)	HMAC_Update(&ctx, buf, len)
#define HMAC_finish(ctx, dig, dlen)	HMAC_Final(&ctx, dig, &dlen); HMAC_CTX_cleanup(&ctx)

/* local includes */
#include "rtmp.h"
#include "mediaserver.h"

#define RTMP_SIG_SIZE 1536
#define SHA256_DIGEST_LENGTH 32

static const uint8_t genuine_fms_key[] = {
  0x47, 0x65, 0x6e, 0x75, 0x69, 0x6e, 0x65, 0x20, 0x41, 0x64, 0x6f, 0x62,
    0x65, 0x20, 0x46, 0x6c,
  0x61, 0x73, 0x68, 0x20, 0x4d, 0x65, 0x64, 0x69, 0x61, 0x20, 0x53, 0x65,
    0x72, 0x76, 0x65, 0x72,
  0x20, 0x30, 0x30, 0x31,	/* Genuine Adobe Flash Media Server 001 */

  0xf0, 0xee, 0xc2, 0x4a, 0x80, 0x68, 0xbe, 0xe8, 0x2e, 0x00, 0xd0, 0xd1,
  0x02, 0x9e, 0x7e, 0x57, 0x6e, 0xec, 0x5d, 0x2d, 0x29, 0x80, 0x6f, 0xab,
    0x93, 0xb8, 0xe6, 0x36,
  0xcf, 0xeb, 0x31, 0xae
};				/* 68 */

static const uint8_t genuine_fp_key[] = {
  0x47, 0x65, 0x6E, 0x75, 0x69, 0x6E, 0x65, 0x20, 0x41, 0x64, 0x6F, 0x62,
    0x65, 0x20, 0x46, 0x6C,
  0x61, 0x73, 0x68, 0x20, 0x50, 0x6C, 0x61, 0x79, 0x65, 0x72, 0x20, 0x30,
    0x30, 0x31,			/* Genuine Adobe Flash Player 001 */
  0xF0, 0xEE,
  0xC2, 0x4A, 0x80, 0x68, 0xBE, 0xE8, 0x2E, 0x00, 0xD0, 0xD1, 0x02, 0x9E,
    0x7E, 0x57, 0x6E, 0xEC,
  0x5D, 0x2D, 0x29, 0x80, 0x6F, 0xAB, 0x93, 0xB8, 0xE6, 0x36, 0xCF, 0xEB,
    0x31, 0xAE
};				/* 62 */



// 772 is for FP10, 8 otherwise.
const static int digest_offset_values[] = { 8, 772 };

const static int dh_offset_values[] = { 1532, 768 };

// offset for the diffie-hellman key pair. rtmpe only; unused now
static unsigned int
get_dh_offset(uint8_t *handshake, unsigned int len,
              int initial_offset, int second_offset)
{
  unsigned int offset = 0;
  uint8_t *ptr = handshake + initial_offset;

  offset += (*ptr);
  ptr++;
  offset += (*ptr);
  ptr++;
  offset += (*ptr);
  ptr++;
  offset += (*ptr);

  offset = (offset % 632) + second_offset;

  if (offset + 128 > (initial_offset - 1)) {
    fprintf(stderr, "Couldn't calculate correct DH offset (got %d), "
                     "exiting!", offset);
    //TODO close cxn here
  }
  return offset;
}

static int get_digest_offset(unsigned char *b, int initial_offset)
{
    unsigned char *ptr = b+initial_offset;
    unsigned int offset = 0;

    offset += *ptr;
    ptr++;
    offset += *ptr;
    ptr++;
    offset += *ptr;
    ptr++;
    offset += *ptr;

    // we deal with some mysterious numbers here
    offset = (offset % 728) + initial_offset + 4;
    if (offset + 32 > initial_offset + 765) {
        fprintf(stderr, "Digest offset calculations whacked\n");
        //TODO close cxn here
    }

    return offset;
}

/* Calculates a HMAC-SHA256. */
static void hmac(const uint8_t *message, size_t messageLen,
                 const uint8_t *key, size_t keylen, uint8_t *digest)
{
  unsigned int digestLen;
  HMAC_CTX ctx;

  HMAC_setup(ctx, key, keylen);
  HMAC_crunch(ctx, message, messageLen);
  HMAC_finish(ctx, digest, digestLen);

  assert(digestLen == 32);
}

static void calc_digest(unsigned int digestPos, uint8_t *handshake_msg,
                        const unsigned char *key, size_t keylen,
                        uint8_t *digest)
{
    const int messageLen = RTMP_SIG_SIZE - SHA256_DIGEST_LENGTH;
    uint8_t message[RTMP_SIG_SIZE - SHA256_DIGEST_LENGTH];

    memcpy(message, handshake_msg, digestPos);
    memcpy(message + digestPos,
	       &handshake_msg[digestPos + SHA256_DIGEST_LENGTH],
    messageLen - digestPos);
    hmac(message, messageLen, key, keylen, digest);
}


static inline int cmp_digest(unsigned int digestPos, uint8_t* handshake_msg,
                          const uint8_t *key, size_t keylen)
{
    uint8_t the_digest[SHA256_DIGEST_LENGTH];
    calc_digest(digestPos, handshake_msg, key, keylen, the_digest);

    return memcmp(&handshake_msg[digestPos], the_digest, SHA256_DIGEST_LENGTH) == 0;
}

// returns the offset of the signature, zero if digest is invalid.
static int verify_digest(uint8_t* msg, const uint8_t *key, size_t keylen, int offidx)
{
    int off = get_digest_offset(msg, digest_offset_values[offidx]);
    if (cmp_digest(off, msg, key, keylen))
        return off;

    off = get_digest_offset(msg, digest_offset_values[offidx^1]);
    if (cmp_digest(off, msg, key, keylen))
        return off;

    return 0;
}

static uint32_t clk_tck;
static uint32_t get_uptime()
{
    struct tms t;
    if (!clk_tck) clk_tck = sysconf(_SC_CLK_TCK);
    return times(&t) * 1000 / clk_tck;
}

%%{
    machine rtmp_handshake;
    alphtype unsigned char;

    action unversioned_response {
        fprintf(stdout, "Do old fashioned handshake here\n");
    }

    action versioned_response {
        int sent, type, i, size, *bi;
        uint32_t uptime;
        unsigned char *b = r->write_buf, *bend = b+1+RTMP_SIG_SIZE;
        unsigned char *signature;

        fprintf(stdout, "received handshake type %u \n", version);

        *b++ = version;  // copy version given by client
        uptime = htonl(get_uptime());
        memcpy(b, &uptime, 4); // timestamp
        b += 4;

        // server version. FP9 only
        *b++ = FMS_VER_MAJOR;
        *b++ = FMS_VER_MINOR;
        *b++ = FMS_VER_MICRO;
        *b++ = FMS_VER_NANO;

        // random bytes to complete the handshake
        bi = (int*)b;
        for (i = 2; i < RTMP_SIG_SIZE/4; i++)
            *bi++ = rand();
        b = r->write_buf+1;

        b = r->write_buf+1;

        if (p[4]) {
            // imprint key
            r->off = get_digest_offset(b, digest_offset_values[digoff_init]);
            calc_digest(r->off, b, genuine_fms_key, 36, b+r->off);
        } else
            r->off = 0;

        send(r->fd, r->write_buf, (bend - r->write_buf), 0);
        fprintf(stdout, "sent: %d bytes\n", bend - r->write_buf);

        // decode client request
        memcpy(&uptime, p, 4);
        uptime = ntohl(uptime);
        fprintf(stdout, "client uptime: %d\n", uptime);
        fprintf(stdout, "player version: %d.%d.%d.%d\n", p[4], p[5], p[6], p[7]);

        // only if this is a Flash Player 9+ handshake
        // FP9 handshakes are only if major player version is >0
        if (r->off) {
            unsigned char the_digest[SHA256_DIGEST_LENGTH];
            int off;
            if (!(off = verify_digest(p, genuine_fp_key, 30, digoff_init))) {
                fprintf(stderr, "client digest failed\n");
                //TODO something drastic
            }
            fprintf(stdout, "client digest passed\n");

            // TODO check for overflow here
            if ((pe - p) != RTMP_SIG_SIZE) {
                fprintf(stderr, "Client buffer not big enough\n");
                // TODO something drastic.
                // Perhaps the size should be checked earlier.
            }

            // imprint server signature into client response
            signature = p+RTMP_SIG_SIZE-SHA256_DIGEST_LENGTH;
            hmac(&p[off], SHA256_DIGEST_LENGTH, genuine_fms_key,
                       sizeof(genuine_fms_key), the_digest);
            hmac(p, RTMP_SIG_SIZE - SHA256_DIGEST_LENGTH, the_digest,
                       SHA256_DIGEST_LENGTH, signature);
        }
        send(r->fd, p, RTMP_SIG_SIZE, 0);
        r->cs = cs; // save state
        fbreak;
    }

    action enc {
        version = fc;
        digoff_init = 1;
        p += 1;
        fprintf(stdout, "Received a request for an encrypted session. %d\n", version);
        // XXX '128' at the fifth byte indicates a Flash 10 session.
        // XXX RTMPE type 8 involves XTEA encryption of the signature.
    }

    action plain {
        version = fc;
        digoff_init = 0;
        p += 1;
        fprintf(stdout, "plain handshake, version %d\n", version);
    }

    action unsupported {
        fprintf(stdout, "Received unsuported rtmp handshake type %u, "
                        "disconecting fd %d\n", fc, r->fd);
        ev_io_stop(ctx->loop, io);
        close(r->fd);
        return;
    }

    action versioned_response2 {
        // second part of the handshake.
        if ((pe - p) < RTMP_SIG_SIZE) {
            fprintf(stderr, "Did not receive enough bytes from handshake response, expected %d got %d\n", RTMP_SIG_SIZE, pe - p);
            // TODO something drastic
            fbreak;
        }

        // FP9 only
        if (r->off) {
            unsigned char signature[SHA256_DIGEST_LENGTH];
            unsigned char thedigest[SHA256_DIGEST_LENGTH];
            unsigned char *b = r->write_buf+1;
            // verify client response
            hmac(&b[r->off], SHA256_DIGEST_LENGTH, genuine_fp_key,
                 sizeof(genuine_fp_key), thedigest);
            hmac(p, RTMP_SIG_SIZE - SHA256_DIGEST_LENGTH, thedigest,
                 SHA256_DIGEST_LENGTH, signature);
            if (memcmp(signature, &p[RTMP_SIG_SIZE - SHA256_DIGEST_LENGTH],
                       SHA256_DIGEST_LENGTH)) {
                fprintf(stderr, "Client not genuine Adobe\n");
                // TODO something drastic
                fbreak;
            }
        }
        // we should verify the bytes returned match in pre-fp9 handshakes
        // but: Postel's Law.

        fprintf(stdout, "Great success: client handshake successful!\n");
        p += RTMP_SIG_SIZE;
        // process the rest
    }

    # handshake types.
    # note that actions are executed in the order they are visited
    plain_handshake = 0x03;
    encrypted_handshake = 0x06 | 0x08; # only invoked for rtmpe

    handshake_type = plain_handshake > plain | encrypted_handshake > enc;
    part1 = handshake_type @ versioned_response | 0x0..0xff @ unsupported;

    part2 = 0x0..0xff >versioned_response2;

    # states of the main machine
    handshake = part1 part2;
    main := handshake;
}%%

%% write data;

int rtmp_parser_init(rtmp *r)
{
    int cs = 0; // ragel specific variable
    %% write init;

    rtmp_init(r);
    r->cs = cs;
}

static inline rtmp* get_rtmp(ev_io *w)
{
    return (rtmp*)((char*)w - offsetof(rtmp, read_watcher));
}

void rtmp_read(struct ev_loop *loop, ev_io *io, int revents)
{
    unsigned char *p, *pe; // ragel specific variables
    rtmp *r = get_rtmp(io);
    srv_ctx *ctx = io->data;
    int cs = r->cs;

    // locally scoped stuff thats also used within actions
    unsigned char version;
    int digoff_init;

    // make sure this is nonblocking
    int len = recv(r->fd, r->read_buf, sizeof(r->write_buf), 0);
    if (!len)
    {
        fprintf(stderr, "Bad read, disconnecting fd %d\n", r->fd);
        ev_io_stop(ctx->loop, io);
        close(r->fd);
        return;
    }

    printf("processing rtmp packet (length %d)\n", len);
    p = r->read_buf;
    pe = r->read_buf+len;

    %%write exec;

    fprintf(stdout, "finished processing rtmp packet.\n");
    r->cs = cs;
}
