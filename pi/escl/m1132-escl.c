/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * m1132-escl - eSCL (AirScan) scanner service for the USB-attached
 * HP LaserJet Professional M1132 MFP, Linux edition for the Raspberry Pi.
 *
 * It drives the scanner over USB (libusb-1.0) and serves it as an eSCL
 * scanner on the LAN, so Image Capture, Preview, NAPS2 and sane-airscan can
 * use it. The _uscan._tcp announcement is done by Avahi from a static
 * service file (see pi/m1132-escl.avahi.service).
 *
 * This is a port of scanner/m1132-escl.swift (same protocol, same eSCL
 * surface). USB protocol: "PROTOCOL.md" of https://github.com/F1f0mp4/m1132-scan
 * (Filip Tarcala, MIT), derived from HP's macOS driver.
 *
 *   m1132-escl [--port N]
 *
 * Build: see Makefile (libusb-1.0, libjpeg, libpng, libmicrohttpd).
 */

#define _GNU_SOURCE
#include <errno.h>
#include <getopt.h>
#include <netdb.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <jpeglib.h>
#include <libusb-1.0/libusb.h>
#include <microhttpd.h>
#ifdef HAVE_PNG
#include <png.h>
#endif

/* ---- Constants ---------------------------------------------------------- */

#define USB_VENDOR   0x03F0
#define USB_PRODUCT  0x042A
#define MAGIC        0x41535001u          /* "ASP\x01" */
#define GLASS_RIGHT  850u                 /* 1/100 inch, glass is 8.50 x 11.22 in */
#define GLASS_BOTTOM 1122u
#define MAX_JOBS     10
#define XFER_SIZE    65536

static const uint32_t resolutions[] = { 150, 300, 600 };   /* 1200 dpi untested */
static const char make_and_model[] = "HP LaserJet Professional M1132 MFP";
static const char scanner_uuid[] = "4d313133-3200-4e61-7469-766561726d36";

static void logmsg(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static uint32_t be32_get(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static void be32_put(uint8_t *p, uint32_t v)
{
    p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

/* 32-byte message header: magic, id, param1, param2, status, length, 0, 0. */
static void msg_header(uint8_t h[32], uint32_t id, uint32_t length)
{
    memset(h, 0, 32);
    be32_put(h, MAGIC);
    be32_put(h + 4, id);
    be32_put(h + 20, length);
}

/* Growable byte buffer. */
struct buf { uint8_t *p; size_t len, cap; };

static int buf_reserve(struct buf *b, size_t extra)
{
    if (b->len + extra <= b->cap) return 0;
    size_t cap = b->cap ? b->cap : 4096;
    while (cap < b->len + extra) cap *= 2;
    uint8_t *p = realloc(b->p, cap);
    if (!p) return -1;
    b->p = p; b->cap = cap;
    return 0;
}

static int buf_append(struct buf *b, const void *d, size_t n)
{
    if (buf_reserve(b, n) < 0) return -1;
    memcpy(b->p + b->len, d, n);
    b->len += n;
    return 0;
}

static int buf_printf(struct buf *b, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0 || buf_reserve(b, (size_t)n + 1) < 0) return -1;
    va_start(ap, fmt);
    vsnprintf((char *)b->p + b->len, (size_t)n + 1, fmt, ap);
    va_end(ap);
    b->len += (size_t)n;
    return 0;
}

static void buf_free(struct buf *b)
{
    free(b->p);
    b->p = NULL; b->len = b->cap = 0;
}

/* ---- USB transport ------------------------------------------------------ */

struct scanner {
    libusb_context *ctx;
    libusb_device_handle *dev;
    int ifnum;
    uint8_t ep_out, ep_in;
    struct buf in;            /* the IN pipe is a byte stream, keep surplus bytes */
    size_t in_off;            /* consumed prefix of in */
    char err[160];
};

static int fail(struct scanner *s, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(s->err, sizeof s->err, fmt, ap);
    va_end(ap);
    return -1;
}

static void usb_close(struct scanner *s)
{
    if (s->dev) {
        libusb_release_interface(s->dev, s->ifnum);
        libusb_close(s->dev);
        s->dev = NULL;
    }
    if (s->ctx) { libusb_exit(s->ctx); s->ctx = NULL; }
    buf_free(&s->in);
}

/* The scan interface is the vendor-specific one (class/subclass/protocol FF/FF/FF);
 * use its first bulk OUT and bulk IN endpoint (alternate setting 0). The printer
 * interface (7/1/x) is never touched, so CUPS keeps working. */
static int usb_open(struct scanner *s)
{
    memset(s, 0, sizeof *s);
    if (libusb_init(&s->ctx) < 0) return fail(s, "libusb init failed");
    s->dev = libusb_open_device_with_vid_pid(s->ctx, USB_VENDOR, USB_PRODUCT);
    if (!s->dev) return fail(s, "scanner not found (printer off, unplugged, or no USB permission?)");

    libusb_device *d = libusb_get_device(s->dev);
    struct libusb_config_descriptor *cfg;
    if (libusb_get_active_config_descriptor(d, &cfg) < 0) return fail(s, "cannot read USB configuration");
    int found = 0;
    for (int i = 0; i < cfg->bNumInterfaces && !found; i++) {
        if (cfg->interface[i].num_altsetting < 1) continue;
        const struct libusb_interface_descriptor *a = &cfg->interface[i].altsetting[0];
        if (a->bInterfaceClass != 0xFF || a->bInterfaceSubClass != 0xFF || a->bInterfaceProtocol != 0xFF) continue;
        s->ifnum = a->bInterfaceNumber;
        s->ep_out = s->ep_in = 0;
        for (int e = 0; e < a->bNumEndpoints; e++) {
            const struct libusb_endpoint_descriptor *ep = &a->endpoint[e];
            if ((ep->bmAttributes & 3) != LIBUSB_TRANSFER_TYPE_BULK) continue;
            if (ep->bEndpointAddress & 0x80) { if (!s->ep_in) s->ep_in = ep->bEndpointAddress; }
            else if (!s->ep_out) s->ep_out = ep->bEndpointAddress;
        }
        found = 1;
    }
    libusb_free_config_descriptor(cfg);
    if (!found) return fail(s, "no vendor-specific scan interface on the device");
    if (!s->ep_out || !s->ep_in) return fail(s, "no bulk endpoints on the scan interface");

    libusb_set_auto_detach_kernel_driver(s->dev, 1);
    int r = libusb_claim_interface(s->dev, s->ifnum);
    if (r < 0) return fail(s, "cannot claim scan interface: %s", libusb_strerror(r));
    return 0;
}

static int usb_send(struct scanner *s, const uint8_t *d, int len)
{
    int n = 0;
    int r = libusb_bulk_transfer(s->dev, s->ep_out, (uint8_t *)d, len, &n, 5000);
    if (r < 0) return fail(s, "USB write failed: %s", libusb_strerror(r));
    if (n != len) return fail(s, "short USB write %d/%d", n, len);
    return 0;
}

/* One bulk IN transfer appended to the surplus buffer. Returns 1 if data
 * arrived, 0 on timeout, -1 on error. */
static int usb_transfer(struct scanner *s, double timeout_s)
{
    if (buf_reserve(&s->in, XFER_SIZE) < 0) return fail(s, "out of memory");
    int ms = timeout_s > 0 ? (int)(timeout_s * 1000) : 1;
    int n = 0;
    int r = libusb_bulk_transfer(s->dev, s->ep_in, s->in.p + s->in.len, XFER_SIZE, &n, ms);
    if (r == 0 || r == LIBUSB_ERROR_TIMEOUT) {
        s->in.len += (size_t)n;
        return r == 0 ? 1 : 0;
    }
    return fail(s, "USB read failed: %s", libusb_strerror(r));
}

static size_t usb_avail(const struct scanner *s) { return s->in.len - s->in_off; }

static int usb_read(struct scanner *s, uint8_t *dst, size_t count, double timeout_s)
{
    double deadline = now_s() + timeout_s;
    while (usb_avail(s) < count) {
        double left = deadline - now_s();
        if (left <= 0) return fail(s, "scanner timeout");
        if (s->in_off) {                      /* compact before reading more */
            memmove(s->in.p, s->in.p + s->in_off, usb_avail(s));
            s->in.len -= s->in_off;
            s->in_off = 0;
        }
        if (usb_transfer(s, left) < 0) return -1;
    }
    memcpy(dst, s->in.p + s->in_off, count);
    s->in_off += count;
    return 0;
}

/* Discard whatever arrives within timeout_s. */
static int usb_drain(struct scanner *s, double timeout_s)
{
    s->in.len = s->in_off = 0;
    double deadline = now_s() + timeout_s;
    for (;;) {
        double left = deadline - now_s();
        if (left <= 0) return 0;
        int r = usb_transfer(s, left);
        if (r < 0) return -1;
        s->in.len = 0;
        if (r == 0) return 0;
    }
}

/* Send a command and read its 32-byte reply: status and payload length. */
static int usb_command(struct scanner *s, uint32_t id, const uint8_t *payload, uint32_t plen,
                       uint32_t *status, uint32_t *length)
{
    uint8_t *m = malloc(32 + plen);
    if (!m) return fail(s, "out of memory");
    msg_header(m, id, plen);
    if (plen) memcpy(m + 32, payload, plen);
    int r = usb_send(s, m, 32 + (int)plen);
    free(m);
    if (r < 0) return -1;
    uint8_t h[32];
    if (usb_read(s, h, 32, 10) < 0) return -1;
    if (be32_get(h) != MAGIC || be32_get(h + 4) != id) return fail(s, "bad reply to command 0x%x", id);
    *status = be32_get(h + 16);
    *length = be32_get(h + 20);
    return 0;
}

static int usb_simple(struct scanner *s, uint32_t id)
{
    uint8_t h[32];
    msg_header(h, id, 0);
    return usb_send(s, h, 32);
}

/* ---- Scan engine -------------------------------------------------------- */

enum color_mode { MODE_RGB, MODE_GRAY, MODE_BW };
static const char *mode_names[] = { "RGB24", "Grayscale8", "BlackAndWhite1" };

struct scan_params {
    uint32_t dpi;
    enum color_mode mode;
    uint32_t left, top;          /* 1/100 inch from the glass corner */
    uint32_t width, height;
};

struct raw_image { int width, height, channels, dpi; uint8_t *pixels; size_t len; };

#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))

/* One flatbed scan. Session order as HP's driver: lock, reset defaults, read
 * back, edit resolution/window/colour, write, start, read the packet stream.
 * On failure returns -1 with the reason in err. */
static int scan_run(const struct scan_params *p, volatile int *cancel, struct raw_image *img,
                    char *err, size_t errlen)
{
    struct scanner s;
    struct buf pixels = {0}, carry = {0}, body = {0};
    uint32_t status, length;
    int locked = 0, open = 0, cancel_sent = 0, rc = -1;
    int channels = p->mode == MODE_RGB ? 3 : 1;
    int width = 0, rows = 0;

    if (usb_open(&s) < 0) goto out;

    if (usb_simple(&s, 0x15) < 0) goto out;              /* fire-and-forget before the lock */
    if (usb_drain(&s, 1) < 0) goto out;
    for (int i = 0; i < 30 && !locked; i++) {
        if (usb_command(&s, 0x00, NULL, 0, &status, &length) < 0) goto out;
        if (status == 0) locked = 1; else sleep(1);
    }
    if (!locked) { fail(&s, "scanner busy (lock refused)"); goto out; }

    if (usb_command(&s, 0x08, NULL, 0, &status, &length) < 0) goto out;
    if (status != 0) { fail(&s, "default settings refused"); goto out; }
    if (usb_command(&s, 0x06, NULL, 0, &status, &length) < 0) goto out;
    if (status != 0 || length != 100) { fail(&s, "cannot read settings"); goto out; }
    uint8_t block[100];
    if (usb_read(&s, block, 100, 60) < 0) goto out;
    uint32_t v[25];
    for (int i = 0; i < 25; i++) v[i] = be32_get(block + i * 4);

    /* Fields: 3 resolution, 16-19 window top/left/bottom/right, 20-23 scannable
     * area, 24 colour type (1 colour, 0 grey; black & white is grey + threshold).
     * The firmware overstates the glass length, so clamp to the real glass. */
    uint32_t max_right = MIN(v[23], GLASS_RIGHT), max_bottom = MIN(v[22], GLASS_BOTTOM);
    v[3] = p->dpi;
    v[17] = MIN(v[21] + p->left, max_right - 1);
    v[16] = MIN(v[20] + p->top, max_bottom - 1);
    v[19] = MIN(v[17] + MAX(p->width, 1u), max_right);
    v[18] = MIN(v[16] + MAX(p->height, 1u), max_bottom);
    v[24] = p->mode == MODE_RGB ? 1 : 0;
    for (int i = 0; i < 25; i++) be32_put(block + i * 4, v[i]);
    if (usb_command(&s, 0x07, block, 100, &status, &length) < 0) goto out;
    if (status != 0) { fail(&s, "scan settings refused"); goto out; }

    width = (int)((v[19] - v[17]) * p->dpi / 100);
    rows = (int)((v[18] - v[16]) * p->dpi / 100);
    if (buf_reserve(&pixels, (size_t)width * rows * channels) < 0) { fail(&s, "out of memory"); goto out; }

    if (usb_command(&s, 0x02, NULL, 0, &status, &length) < 0) goto out;
    if (status != 0) { fail(&s, "scan start refused"); goto out; }
    open = 1;

    for (;;) {
        if (*cancel && !cancel_sent) {
            if (usb_simple(&s, 0x03) < 0) goto out;
            cancel_sent = 1;
        }
        uint8_t h[32];
        if (usb_read(&s, h, 32, 60) < 0) goto out;
        if (be32_get(h) != MAGIC) { fail(&s, "lost sync with the scanner"); goto out; }
        uint32_t id = be32_get(h + 4), len = be32_get(h + 20);
        body.len = 0;
        if (len) {
            if (buf_reserve(&body, len) < 0) { fail(&s, "out of memory"); goto out; }
            if (usb_read(&s, body.p, len, 60) < 0) goto out;
            body.len = len;
        }

        switch (id) {
        case 0x05: {                                    /* image data: 24-byte header + lines */
            if (len < 24) { fail(&s, "short image packet"); goto out; }
            uint32_t type = be32_get(body.p);
            int stride = (int)be32_get(body.p + 20);
            if (be32_get(body.p + 12) != 1 || !((type == 10 && channels == 3) || (type == 6 && channels == 1))) {
                fail(&s, "unexpected image data type %u", type); goto out;
            }
            if (stride < width) {                       /* firmware rounds rows to 16 px */
                if (pixels.len) { fail(&s, "row width changed mid-scan"); goto out; }
                width = stride;
            }
            if (stride <= 0) { fail(&s, "bad row stride"); goto out; }
            if (buf_append(&carry, body.p + 24, len - 24) < 0) { fail(&s, "out of memory"); goto out; }
            /* Colour rows arrive as R, G, B lines of `stride` bytes; grey as one line. */
            size_t row_bytes = (size_t)stride * channels;
            size_t whole = carry.len / row_bytes;
            if (buf_reserve(&pixels, whole * width * channels) < 0) { fail(&s, "out of memory"); goto out; }
            for (size_t y = 0; y < whole; y++) {
                const uint8_t *src = carry.p + y * row_bytes;
                uint8_t *dst = pixels.p + pixels.len;
                if (channels == 1) {
                    memcpy(dst, src, width);
                } else {
                    for (int x = 0; x < width; x++) {
                        dst[x * 3] = src[x];
                        dst[x * 3 + 1] = src[stride + x];
                        dst[x * 3 + 2] = src[2 * stride + x];
                    }
                }
                pixels.len += (size_t)width * channels;
            }
            memmove(carry.p, carry.p + whole * row_bytes, carry.len - whole * row_bytes);
            carry.len -= whole * row_bytes;
            break;
        }
        case 0x18:                                      /* e_NewScanPage needs an ack */
            if (usb_simple(&s, 0x18) < 0) goto out;
            break;
        case 0x0C: {                                    /* e_EndJob */
            open = 0;
            if (cancel_sent) { fail(&s, "cancelled"); goto out; }
            int got = (int)MIN(pixels.len / ((size_t)width * channels), (size_t)rows);
            img->width = width; img->height = got; img->channels = channels; img->dpi = (int)p->dpi;
            img->len = (size_t)got * width * channels;
            img->pixels = pixels.p; pixels.p = NULL;
            rc = 0;
            goto out;
        }
        case 0x04:                                      /* e_AbortScanJob */
            open = 0;
            fail(&s, cancel_sent ? "cancelled" : "scanner aborted the scan");
            goto out;
        case 0x09: case 0x0A: case 0x0B: case 0x0D: case 0x0E:   /* job/sheet/page start and end */
            break;
        default:
            fail(&s, "unexpected packet 0x%x", id);
            goto out;
        }
    }

out:
    if (rc < 0) snprintf(err, errlen, "%s", s.err[0] ? s.err : "scan failed");
    if (s.dev) {
        if (open) {                                     /* error mid-scan: stop the head */
            usb_simple(&s, 0x03);
            usb_drain(&s, 5);
        }
        if (locked) { uint32_t st, ln; usb_command(&s, 0x01, NULL, 0, &st, &ln); }   /* unlock */
    }
    usb_close(&s);
    buf_free(&pixels); buf_free(&carry); buf_free(&body);
    return rc;
}

/* ---- Output formats ----------------------------------------------------- */

static void threshold_bw(struct raw_image *img)        /* like HP's driver */
{
    for (size_t i = 0; i < img->len; i++) img->pixels[i] = img->pixels[i] >= 128 ? 255 : 0;
}

static int encode_jpeg(const struct raw_image *img, struct buf *out)
{
    struct jpeg_compress_struct c;
    struct jpeg_error_mgr jerr;
    unsigned char *mem = NULL;
    unsigned long mem_len = 0;

    c.err = jpeg_std_error(&jerr);
    jpeg_create_compress(&c);
    jpeg_mem_dest(&c, &mem, &mem_len);
    c.image_width = (JDIMENSION)img->width;
    c.image_height = (JDIMENSION)img->height;
    c.input_components = img->channels;
    c.in_color_space = img->channels == 3 ? JCS_RGB : JCS_GRAYSCALE;
    jpeg_set_defaults(&c);
    jpeg_set_quality(&c, 90, TRUE);
    c.density_unit = 1;                                 /* dots per inch */
    c.X_density = c.Y_density = (UINT16)img->dpi;
    jpeg_start_compress(&c, TRUE);
    size_t row = (size_t)img->width * img->channels;
    while (c.next_scanline < c.image_height) {
        JSAMPROW r = img->pixels + c.next_scanline * row;
        jpeg_write_scanlines(&c, &r, 1);
    }
    jpeg_finish_compress(&c);
    jpeg_destroy_compress(&c);
    int rc = buf_append(out, mem, mem_len);
    free(mem);
    return rc;
}

#ifdef HAVE_PNG
static void png_write_cb(png_structp png, png_bytep data, png_size_t n)
{
    struct buf *b = png_get_io_ptr(png);
    if (buf_append(b, data, n) < 0) png_error(png, "out of memory");
}

static void png_flush_cb(png_structp png) { (void)png; }

static int encode_png(const struct raw_image *img, struct buf *out)
{
    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png) return -1;
    png_infop info = png_create_info_struct(png);
    if (!info) { png_destroy_write_struct(&png, NULL); return -1; }
    if (setjmp(png_jmpbuf(png))) { png_destroy_write_struct(&png, &info); return -1; }
    png_set_write_fn(png, out, png_write_cb, png_flush_cb);
    png_set_IHDR(png, info, (png_uint_32)img->width, (png_uint_32)img->height, 8,
                 img->channels == 3 ? PNG_COLOR_TYPE_RGB : PNG_COLOR_TYPE_GRAY,
                 PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    png_uint_32 ppm = (png_uint_32)(img->dpi / 0.0254 + 0.5);
    png_set_pHYs(png, info, ppm, ppm, PNG_RESOLUTION_METER);
    png_write_info(png, info);
    size_t row = (size_t)img->width * img->channels;
    for (int y = 0; y < img->height; y++) png_write_row(png, img->pixels + y * row);
    png_write_end(png, NULL);
    png_destroy_write_struct(&png, &info);
    return 0;
}
#endif

/* Single-page PDF wrapping the JPEG as a DCTDecode image XObject. */
static int encode_pdf(const struct raw_image *img, struct buf *out)
{
    struct buf jpeg = {0};
    if (encode_jpeg(img, &jpeg) < 0) return -1;
    double w = (double)img->width * 72 / img->dpi, h = (double)img->height * 72 / img->dpi;
    char content[96];
    int clen = snprintf(content, sizeof content, "q %.2f 0 0 %.2f 0 0 cm /Im0 Do Q\n", w, h);
    size_t off[6];
    int rc = -1;

    if (buf_printf(out, "%%PDF-1.4\n%%\xE2\xE3\xCF\xD3\n") < 0) goto done;
    off[1] = out->len;
    if (buf_printf(out, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n") < 0) goto done;
    off[2] = out->len;
    if (buf_printf(out, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n") < 0) goto done;
    off[3] = out->len;
    if (buf_printf(out, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.2f %.2f] "
                        "/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>\nendobj\n", w, h) < 0) goto done;
    off[4] = out->len;
    if (buf_printf(out, "4 0 obj\n<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /%s "
                        "/BitsPerComponent 8 /Filter /DCTDecode /Length %zu >>\nstream\n",
                   img->width, img->height, img->channels == 3 ? "DeviceRGB" : "DeviceGray", jpeg.len) < 0) goto done;
    if (buf_append(out, jpeg.p, jpeg.len) < 0) goto done;
    if (buf_printf(out, "\nendstream\nendobj\n") < 0) goto done;
    off[5] = out->len;
    if (buf_printf(out, "5 0 obj\n<< /Length %d >>\nstream\n%s\nendstream\nendobj\n", clen, content) < 0) goto done;
    size_t xref = out->len;
    if (buf_printf(out, "xref\n0 6\n0000000000 65535 f \n") < 0) goto done;
    for (int i = 1; i <= 5; i++)
        if (buf_printf(out, "%010zu 00000 n \n", off[i]) < 0) goto done;
    if (buf_printf(out, "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%zu\n%%%%EOF\n", xref) < 0) goto done;
    rc = 0;
done:
    buf_free(&jpeg);
    return rc;
}

/* Encode a scan as the eSCL document format the client asked for. */
static int document(struct raw_image *img, enum color_mode mode, const char *format,
                    struct buf *out, const char **ctype)
{
    if (mode == MODE_BW) threshold_bw(img);
#ifdef HAVE_PNG
    if (strcmp(format, "image/png") == 0) { *ctype = "image/png"; return encode_png(img, out); }
#endif
    if (strcmp(format, "application/pdf") == 0) { *ctype = "application/pdf"; return encode_pdf(img, out); }
    *ctype = "image/jpeg";
    return encode_jpeg(img, out);
}

/* ---- eSCL jobs ---------------------------------------------------------- */

enum job_state { JOB_FREE, JOB_PROCESSING, JOB_COMPLETED, JOB_ABORTED };
static const char *state_names[] = { "", "Processing", "Completed", "Aborted" };

struct job {
    char id[37];
    unsigned seq;                 /* insertion order; 0 = free slot */
    struct scan_params params;
    char format[48];
    volatile int cancel;
    enum job_state state;
    struct buf out;
    const char *ctype;
    int delivered;
};

static struct job jobs[MAX_JOBS];
static unsigned job_seq;
static pthread_mutex_t jobs_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t jobs_cond = PTHREAD_COND_INITIALIZER;

static void make_uuid(char out[37])
{
    uint8_t b[16];
    if (getrandom(b, sizeof b, 0) != (ssize_t)sizeof b)
        for (size_t i = 0; i < sizeof b; i++) b[i] = (uint8_t)rand();
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    snprintf(out, 37, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
}

/* Callers hold jobs_lock. */
static int scanner_busy_locked(void)
{
    for (int i = 0; i < MAX_JOBS; i++) if (jobs[i].state == JOB_PROCESSING) return 1;
    return 0;
}

static struct job *find_job_locked(const char *id)
{
    for (int i = 0; i < MAX_JOBS; i++) if (jobs[i].seq && strcmp(jobs[i].id, id) == 0) return &jobs[i];
    return NULL;
}

static void *job_worker(void *arg)
{
    struct job *j = arg;
    struct scan_params p = j->params;
    char format[48], err[160];
    snprintf(format, sizeof format, "%s", j->format);
    logmsg("job %s: %s %u dpi, window %u,%u %ux%u/100 in, %s", j->id, mode_names[p.mode], p.dpi,
           p.left, p.top, p.width, p.height, format);

    struct raw_image img = {0};
    struct buf out = {0};
    const char *ctype = NULL;
    int ok = scan_run(&p, &j->cancel, &img, err, sizeof err) == 0;
    if (ok && document(&img, p.mode, format, &out, &ctype) < 0) { ok = 0; snprintf(err, sizeof err, "encoding failed"); }
    if (ok) logmsg("job %s: done, %dx%d px, %zu bytes", j->id, img.width, img.height, out.len);
    else logmsg("job %s: %s", j->id, err);
    free(img.pixels);

    pthread_mutex_lock(&jobs_lock);
    if (ok) { j->out = out; j->ctype = ctype; j->state = JOB_COMPLETED; }
    else { buf_free(&out); j->state = JOB_ABORTED; }
    pthread_cond_broadcast(&jobs_cond);
    pthread_mutex_unlock(&jobs_lock);
    return NULL;
}

/* Registers the job (evicting the oldest finished one) and starts the scan. */
static struct job *start_job(const struct scan_params *p, const char *format, char id_out[37])
{
    pthread_mutex_lock(&jobs_lock);
    struct job *slot = NULL;
    for (int i = 0; i < MAX_JOBS; i++) {
        if (jobs[i].seq == 0) { slot = &jobs[i]; break; }
        if (jobs[i].state != JOB_PROCESSING && (!slot || jobs[i].seq < slot->seq)) slot = &jobs[i];
    }
    buf_free(&slot->out);
    memset(slot, 0, sizeof *slot);
    slot->seq = ++job_seq;
    make_uuid(slot->id);
    slot->params = *p;
    snprintf(slot->format, sizeof slot->format, "%s", format);
    slot->state = JOB_PROCESSING;
    memcpy(id_out, slot->id, 37);
    pthread_mutex_unlock(&jobs_lock);

    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &attr, job_worker, slot) != 0) {
        pthread_mutex_lock(&jobs_lock);
        slot->state = JOB_ABORTED;
        pthread_cond_broadcast(&jobs_cond);
        pthread_mutex_unlock(&jobs_lock);
    }
    pthread_attr_destroy(&attr);
    return slot;
}

/* ---- eSCL XML ----------------------------------------------------------- */

#define XML_HEAD "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
#define XML_NS "xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\" xmlns:pwg=\"http://www.pwg.org/schemas/2010/12/sm\""

static const char *formats[] = { "image/jpeg", "application/pdf",
#ifdef HAVE_PNG
    "image/png",
#endif
};

static int xml_capabilities(struct buf *b)
{
    int r = buf_printf(b, XML_HEAD "<scan:ScannerCapabilities " XML_NS ">\n"
        "<pwg:Version>2.63</pwg:Version>\n<pwg:MakeAndModel>%s</pwg:MakeAndModel>\n<scan:UUID>%s</scan:UUID>\n"
        "<scan:Platen><scan:PlatenInputCaps>\n"
        "<scan:MinWidth>16</scan:MinWidth><scan:MaxWidth>%u</scan:MaxWidth>\n"
        "<scan:MinHeight>16</scan:MinHeight><scan:MaxHeight>%u</scan:MaxHeight>\n"
        "<scan:MaxScanRegions>1</scan:MaxScanRegions>\n<scan:SettingProfiles><scan:SettingProfile>\n"
        "<scan:ColorModes><scan:ColorMode>RGB24</scan:ColorMode><scan:ColorMode>Grayscale8</scan:ColorMode>"
        "<scan:ColorMode>BlackAndWhite1</scan:ColorMode></scan:ColorModes>\n<scan:DocumentFormats>",
        make_and_model, scanner_uuid, GLASS_RIGHT * 3, GLASS_BOTTOM * 3);
    for (size_t i = 0; i < sizeof formats / sizeof *formats && r == 0; i++)
        r = buf_printf(b, "<pwg:DocumentFormat>%s</pwg:DocumentFormat>", formats[i]);
    for (size_t i = 0; i < sizeof formats / sizeof *formats && r == 0; i++)
        r = buf_printf(b, "<scan:DocumentFormatExt>%s</scan:DocumentFormatExt>", formats[i]);
    if (r == 0) r = buf_printf(b, "</scan:DocumentFormats>\n<scan:SupportedResolutions><scan:DiscreteResolutions>");
    for (size_t i = 0; i < sizeof resolutions / sizeof *resolutions && r == 0; i++)
        r = buf_printf(b, "<scan:DiscreteResolution><scan:XResolution>%u</scan:XResolution>"
                          "<scan:YResolution>%u</scan:YResolution></scan:DiscreteResolution>", resolutions[i], resolutions[i]);
    if (r == 0) r = buf_printf(b, "</scan:DiscreteResolutions></scan:SupportedResolutions>\n"
        "<scan:ColorSpaces><scan:ColorSpace>sRGB</scan:ColorSpace></scan:ColorSpaces>\n"
        "</scan:SettingProfile></scan:SettingProfiles>\n"
        "<scan:SupportedIntents><scan:Intent>Document</scan:Intent><scan:Intent>TextAndGraphic</scan:Intent>"
        "<scan:Intent>Photo</scan:Intent><scan:Intent>Preview</scan:Intent></scan:SupportedIntents>\n"
        "<scan:MaxOpticalXResolution>600</scan:MaxOpticalXResolution><scan:MaxOpticalYResolution>600</scan:MaxOpticalYResolution>\n"
        "</scan:PlatenInputCaps></scan:Platen>\n</scan:ScannerCapabilities>\n");
    return r;
}

static int xml_status(struct buf *b)
{
    pthread_mutex_lock(&jobs_lock);
    int r = buf_printf(b, XML_HEAD "<scan:ScannerStatus " XML_NS "><pwg:Version>2.63</pwg:Version><pwg:State>%s</pwg:State><scan:Jobs>",
                       scanner_busy_locked() ? "Processing" : "Idle");
    /* Jobs in insertion order. */
    for (unsigned seq = 1; seq <= job_seq && r == 0; seq++) {
        for (int i = 0; i < MAX_JOBS; i++) {
            const struct job *j = &jobs[i];
            if (j->seq != seq) continue;
            r = buf_printf(b, "<scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/%s</pwg:JobUri><pwg:JobUuid>%s</pwg:JobUuid>"
                              "<scan:Age>0</scan:Age><pwg:ImagesCompleted>%d</pwg:ImagesCompleted>"
                              "<pwg:ImagesToTransfer>%d</pwg:ImagesToTransfer><pwg:JobState>%s</pwg:JobState></scan:JobInfo>",
                           j->id, j->id, j->state == JOB_COMPLETED ? 1 : 0,
                           j->state == JOB_COMPLETED && !j->delivered ? 1 : 0, state_names[j->state]);
        }
    }
    pthread_mutex_unlock(&jobs_lock);
    if (r == 0) r = buf_printf(b, "</scan:Jobs></scan:ScannerStatus>\n");
    return r;
}

/* Text of the first element named `name` (any namespace prefix), trimmed.
 * Good enough for ScanSettings from real eSCL clients. */
static int xml_text(const char *xml, size_t len, const char *name, char *out, size_t outlen)
{
    size_t nlen = strlen(name);
    const char *end = xml + len;
    for (const char *p = xml; (p = memmem(p, (size_t)(end - p), name, nlen)) != NULL; p++) {
        if (p == xml || (p[-1] != '<' && p[-1] != ':')) continue;
        const char *q = p + nlen;
        if (q >= end || (*q != '>' && *q != ' ' && *q != '\t' && *q != '\n' && *q != '/')) continue;
        /* Must be an opening tag: walk back over the namespace prefix to '<'.
         * Hitting '/' first means a closing tag "</pwg:Name>". */
        const char *lt = p;
        while (lt > xml && lt[-1] != '<' && lt[-1] != '/' && lt[-1] != '>') lt--;
        if (lt == xml || lt[-1] != '<') continue;
        const char *gt = memchr(q, '>', (size_t)(end - q));
        if (!gt) return 0;
        if (gt[-1] == '/') continue;                    /* self-closing, no text */
        const char *text = gt + 1;
        const char *close = memchr(text, '<', (size_t)(end - text));
        if (!close) return 0;
        while (text < close && (*text == ' ' || *text == '\t' || *text == '\r' || *text == '\n')) text++;
        while (close > text && (close[-1] == ' ' || close[-1] == '\t' || close[-1] == '\r' || close[-1] == '\n')) close--;
        size_t n = (size_t)(close - text);
        if (n == 0) continue;
        if (n >= outlen) n = outlen - 1;
        memcpy(out, text, n);
        out[n] = 0;
        return 1;
    }
    return 0;
}

static int xml_uint(const char *xml, size_t len, const char *name, uint32_t *v)
{
    char t[32];
    if (!xml_text(xml, len, name, t, sizeof t)) return 0;
    char *e;
    unsigned long u = strtoul(t, &e, 10);
    if (e == t) return 0;
    *v = (uint32_t)u;
    return 1;
}

static void parse_scan_settings(const char *xml, size_t len, struct scan_params *p, char *format, size_t flen)
{
    p->dpi = 300; p->mode = MODE_RGB; p->left = p->top = 0; p->width = GLASS_RIGHT; p->height = GLASS_BOTTOM;
    uint32_t v;
    char t[48];
    if (xml_uint(xml, len, "XResolution", &v)) {
        uint32_t best = resolutions[0];
        for (size_t i = 1; i < sizeof resolutions / sizeof *resolutions; i++)
            if (labs((long)resolutions[i] - (long)v) < labs((long)best - (long)v)) best = resolutions[i];
        p->dpi = best;
    }
    if (xml_text(xml, len, "ColorMode", t, sizeof t)) {
        if (strcmp(t, "Grayscale8") == 0) p->mode = MODE_GRAY;
        else if (strcmp(t, "BlackAndWhite1") == 0) p->mode = MODE_BW;
    }
    /* Region is in 1/300 inch; the scanner works in 1/100 inch. */
    if (xml_uint(xml, len, "XOffset", &v)) p->left = v / 3;
    if (xml_uint(xml, len, "YOffset", &v)) p->top = v / 3;
    if (xml_uint(xml, len, "Width", &v)) p->width = v / 3;
    if (xml_uint(xml, len, "Height", &v)) p->height = v / 3;
    if (!xml_text(xml, len, "DocumentFormatExt", format, flen) && !xml_text(xml, len, "DocumentFormat", format, flen))
        snprintf(format, flen, "image/jpeg");
}

/* ---- HTTP server (libmicrohttpd) ---------------------------------------- */

struct conn { struct buf body; int too_big; };

static enum MHD_Result reply(struct MHD_Connection *c, unsigned code, const char *ctype,
                             void *body, size_t len, enum MHD_ResponseMemoryMode mode,
                             const char *hname, const char *hvalue)
{
    struct MHD_Response *r = MHD_create_response_from_buffer(len, body, mode);
    if (!r) return MHD_NO;
    if (ctype) MHD_add_response_header(r, MHD_HTTP_HEADER_CONTENT_TYPE, ctype);
    if (hname) MHD_add_response_header(r, hname, hvalue);
    MHD_add_response_header(r, MHD_HTTP_HEADER_CONNECTION, "close");
    enum MHD_Result rc = MHD_queue_response(c, code, r);
    MHD_destroy_response(r);
    return rc;
}

static enum MHD_Result reply_empty(struct MHD_Connection *c, unsigned code)
{
    return reply(c, code, NULL, NULL, 0, MHD_RESPMEM_PERSISTENT, NULL, NULL);
}

static enum MHD_Result reply_xml(struct MHD_Connection *c, struct buf *b)
{
    return reply(c, MHD_HTTP_OK, "text/xml", b->p, b->len, MHD_RESPMEM_MUST_FREE, NULL, NULL);
}

static void client_addr(struct MHD_Connection *c, char *out, size_t n)
{
    const union MHD_ConnectionInfo *ci = MHD_get_connection_info(c, MHD_CONNECTION_INFO_CLIENT_ADDRESS);
    out[0] = 0;
    if (!ci || !ci->client_addr) return;
    socklen_t sl = ci->client_addr->sa_family == AF_INET6 ? sizeof(struct sockaddr_in6) : sizeof(struct sockaddr_in);
    getnameinfo(ci->client_addr, sl, out, (socklen_t)n, NULL, 0, NI_NUMERICHOST);
}

static enum MHD_Result handle_request(void *cls, struct MHD_Connection *c, const char *url, const char *method,
                                      const char *version, const char *upload_data, size_t *upload_size, void **con_cls)
{
    (void)cls; (void)version;
    struct conn *cn = *con_cls;
    if (!cn) {
        cn = calloc(1, sizeof *cn);
        if (!cn) return MHD_NO;
        *con_cls = cn;
        return MHD_YES;
    }
    if (*upload_size) {
        if (cn->body.len + *upload_size > (1u << 20) || buf_append(&cn->body, upload_data, *upload_size) < 0) cn->too_big = 1;
        *upload_size = 0;
        return MHD_YES;
    }

    char peer[64];
    client_addr(c, peer, sizeof peer);
    const char *ua = MHD_lookup_connection_value(c, MHD_HEADER_KIND, MHD_HTTP_HEADER_USER_AGENT);
    logmsg("%s %s %s %s", peer, method, url, ua ? ua : "");
    if (cn->too_big) return reply_empty(c, 413);

    /* Split the path: /eSCL/<a>/<b>/<d> */
    char path[256];
    snprintf(path, sizeof path, "%s", url);
    char *parts[4] = {0};
    int np = 0;
    for (char *tok = strtok(path, "/"); tok && np < 4; tok = strtok(NULL, "/")) parts[np++] = tok;
    if (np < 1 || strcmp(parts[0], "eSCL") != 0) return reply_empty(c, MHD_HTTP_NOT_FOUND);
    int get = strcmp(method, "GET") == 0, post = strcmp(method, "POST") == 0, del = strcmp(method, "DELETE") == 0;

    if (get && np == 2 && strcmp(parts[1], "ScannerCapabilities") == 0) {
        struct buf b = {0};
        if (xml_capabilities(&b) < 0) { buf_free(&b); return reply_empty(c, MHD_HTTP_INTERNAL_SERVER_ERROR); }
        return reply_xml(c, &b);
    }
    if (get && np == 2 && strcmp(parts[1], "ScannerStatus") == 0) {
        struct buf b = {0};
        if (xml_status(&b) < 0) { buf_free(&b); return reply_empty(c, MHD_HTTP_INTERNAL_SERVER_ERROR); }
        return reply_xml(c, &b);
    }
    if (post && np == 2 && strcmp(parts[1], "ScanJobs") == 0) {
        pthread_mutex_lock(&jobs_lock);
        int busy = scanner_busy_locked();
        pthread_mutex_unlock(&jobs_lock);
        if (busy) return reply_empty(c, MHD_HTTP_SERVICE_UNAVAILABLE);
        struct scan_params p;
        char format[48], id[37];
        parse_scan_settings((const char *)(cn->body.p ? cn->body.p : (uint8_t *)""), cn->body.len, &p, format, sizeof format);
        start_job(&p, format, id);
        const char *host = MHD_lookup_connection_value(c, MHD_HEADER_KIND, MHD_HTTP_HEADER_HOST);
        char loc[320];
        snprintf(loc, sizeof loc, "http://%s/eSCL/ScanJobs/%s", host ? host : "localhost", id);
        return reply(c, MHD_HTTP_CREATED, NULL, NULL, 0, MHD_RESPMEM_PERSISTENT, MHD_HTTP_HEADER_LOCATION, loc);
    }
    if (get && np == 4 && strcmp(parts[1], "ScanJobs") == 0 && strcmp(parts[3], "NextDocument") == 0) {
        pthread_mutex_lock(&jobs_lock);
        struct job *j = find_job_locked(parts[2]);
        if (!j) { pthread_mutex_unlock(&jobs_lock); return reply_empty(c, MHD_HTTP_NOT_FOUND); }
        unsigned seq = j->seq;
        /* Block until the scan finishes (thread per connection makes this safe). */
        while (j->seq == seq && j->state == JOB_PROCESSING) pthread_cond_wait(&jobs_cond, &jobs_lock);
        void *data = NULL; size_t len = 0; const char *ctype = NULL;
        if (j->seq == seq && j->state == JOB_COMPLETED && !j->delivered) {
            j->delivered = 1;
            data = j->out.p; len = j->out.len; ctype = j->ctype;
            j->out.p = NULL; j->out.len = j->out.cap = 0;    /* ownership moves to the response */
        }
        pthread_mutex_unlock(&jobs_lock);
        if (!data) return reply_empty(c, MHD_HTTP_NOT_FOUND);
        return reply(c, MHD_HTTP_OK, ctype, data, len, MHD_RESPMEM_MUST_FREE, NULL, NULL);
    }
    if (del && np == 3 && strcmp(parts[1], "ScanJobs") == 0) {
        pthread_mutex_lock(&jobs_lock);
        struct job *j = find_job_locked(parts[2]);
        if (j) j->cancel = 1;
        pthread_mutex_unlock(&jobs_lock);
        return reply_empty(c, j ? MHD_HTTP_OK : MHD_HTTP_NOT_FOUND);
    }
    return reply_empty(c, MHD_HTTP_NOT_FOUND);
}

static void request_done(void *cls, struct MHD_Connection *c, void **con_cls, enum MHD_RequestTerminationCode code)
{
    (void)cls; (void)c; (void)code;
    struct conn *cn = *con_cls;
    if (cn) { buf_free(&cn->body); free(cn); *con_cls = NULL; }
}

/* ---- Main --------------------------------------------------------------- */

int main(int argc, char **argv)
{
    unsigned port = 18132;
    static const struct option opts[] = { {"port", required_argument, 0, 'p'}, {"help", no_argument, 0, 'h'}, {0, 0, 0, 0} };
    int o;
    while ((o = getopt_long(argc, argv, "p:h", opts, NULL)) != -1) {
        if (o == 'p') port = (unsigned)strtoul(optarg, NULL, 10);
        else { fprintf(stderr, "usage: m1132-escl [--port N]\n"); return o == 'h' ? 0 : 2; }
    }
    if (port == 0 || port > 65535) { fprintf(stderr, "bad port\n"); return 2; }

    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGINT);
    sigaddset(&set, SIGTERM);
    pthread_sigmask(SIG_BLOCK, &set, NULL);
    signal(SIGPIPE, SIG_IGN);

    unsigned flags = MHD_USE_THREAD_PER_CONNECTION | MHD_USE_INTERNAL_POLLING_THREAD | MHD_USE_ERROR_LOG;
    struct MHD_Daemon *d = MHD_start_daemon(flags | MHD_USE_DUAL_STACK, (uint16_t)port, NULL, NULL, &handle_request, NULL,
                                            MHD_OPTION_NOTIFY_COMPLETED, &request_done, NULL, MHD_OPTION_END);
    if (!d) d = MHD_start_daemon(flags, (uint16_t)port, NULL, NULL, &handle_request, NULL,
                                 MHD_OPTION_NOTIFY_COMPLETED, &request_done, NULL, MHD_OPTION_END);
    if (!d) { logmsg("cannot listen on port %u", port); return 1; }
    logmsg("eSCL scanner \"%s\" on port %u", make_and_model, port);

    int sig;
    sigwait(&set, &sig);
    logmsg("signal %d, exiting", sig);
    MHD_stop_daemon(d);
    return 0;
}
