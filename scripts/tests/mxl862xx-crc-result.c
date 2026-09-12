/* Exercise the real command and API wrapper with deterministic MDIO replies. */
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint16_t __le16;
#define INT_GPHY_READ 0x1801
#define INT_GPHY_WRITE 0x1802
#define SYS_MISC_FW_UPDATE 0x0101
#define MXL862XX_FLAG_CRC_ERR 0
#define MXL862XX_FW_CRC6_ERR (-1024)
#define MXL862XX_FW_CRC16_ERR (-1023)
#define MXL862XX_MMD_REG_CTRL 0
#define MXL862XX_MMD_REG_LEN_RET 1
#define MXL862XX_MMD_REG_DATA_FIRST 2
#define MXL862XX_MMD_REG_DATA_MAX_SIZE 94
#define CTRL_BUSY_MASK 0x8000
#define CTRL_CRC_FLAG 0x4000
#define RST_DATA_THRESHOLD 5
#define MDIO_MUTEX_NESTED 1
#define cpu_to_le16(x) (x)
#define le16_to_cpu(x) (x)
#define dev_err(...) ((void)0)
#define dev_dbg(...) ((void)0)
struct bus { int mdio_lock; };
struct device { struct bus *bus; };
struct work { int unused; };
struct mxl862xx_priv {
    struct device *mdiodev;
    unsigned long flags;
    struct work crc_err_work;
    bool skip_teardown, block_host;
};
static struct bus bus;
static struct device dev = {.bus = &bus};
static struct mxl862xx_priv priv = {.mdiodev = &dev};
static bool bad_crc6, bad_crc16, complete_worker;
static int firmware_result, notifications;
static void require(bool ok, const char *message)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static bool test_and_set_bit(int bit, unsigned long *flags)
{
    bool old = (*flags & (1UL << bit)) != 0;
    *flags |= 1UL << bit;
    return old;
}
static void schedule_work(struct work *work)
{
    (void)work;
    notifications++;
    /* Model the existing worker finishing on another CPU before return. */
    if (complete_worker) priv.flags = 0;
}
static void mutex_lock_nested(int *lock, int subclass)
{ (void)subclass; require(!*lock, "bus lock already held"); *lock = 1; }
static void mutex_unlock(int *lock)
{ require(*lock, "bus lock not held"); *lock = 0; }
static int mxl862xx_reg_write(struct mxl862xx_priv *p, unsigned int reg, u16 data)
{ (void)p; (void)reg; (void)data; return 0; }
static int mxl862xx_reg_read(struct mxl862xx_priv *p, unsigned int reg)
{
    (void)p;
    if (reg == MXL862XX_MMD_REG_LEN_RET) return 0;
    if (reg == MXL862XX_MMD_REG_CTRL) return 0;
    if (reg == MXL862XX_MMD_REG_DATA_FIRST) return 0x1234;
    if (reg == MXL862XX_MMD_REG_DATA_FIRST + 1) return bad_crc16 ? 0 : 0xbeef;
    require(false, "unexpected register read");
    return -EIO;
}
static int mxl862xx_busy_wait(struct mxl862xx_priv *p) { (void)p; return 0; }
static void mxl862xx_crc6_encode(u16 *ctrl, u16 *len) { (void)ctrl; (void)len; }
static int mxl862xx_crc6_verify(u16 ctrl, u16 len, int *result)
{
    (void)ctrl; (void)len;
    *result = firmware_result;
    return bad_crc6 ? -EIO : 0;
}
static u16 crc16(u16 seed, const u8 *data, u16 size)
{ (void)seed; (void)data; (void)size; return 0xbeef; }
static int mxl862xx_rst_data(struct mxl862xx_priv *p) { (void)p; return 0; }
static int mxl862xx_set_data(struct mxl862xx_priv *p, u16 size)
{ (void)p; (void)size; return 0; }
static int mxl862xx_get_data(struct mxl862xx_priv *p, u16 size)
{ (void)p; (void)size; return 0; }
#include "host.inc"

static void reset(int kind, bool completed)
{
    priv.flags = 0;
    notifications = 0;
    complete_worker = completed;
    bad_crc6 = kind == 1;
    bad_crc16 = kind == 4;
    firmware_result = kind == 2 ? MXL862XX_FW_CRC6_ERR :
                      kind == 3 ? MXL862XX_FW_CRC16_ERR :
                      kind == 5 ? -19 : 0;
}
int main(void)
{
    for (int kind = 0; kind <= 5; kind++) {
        for (int completed = 0; completed <= 1; completed++) {
            u16 data = 0x1234;
            reset(kind, completed);
            int ret = mxl862xx_api_wrap(&priv, INT_GPHY_READ, &data, sizeof(data), true, false);
            bool crc = kind >= 1 && kind <= 4;
            require(ret == (crc ? -EBADMSG : kind == 5 ? -EIO : 0),
                    "CRC result must survive worker completion");
            require(notifications == (crc ? 1 : 0), "CRC shutdown notification retained");
            require(bus.mdio_lock == 0, "API must release bus lock");
            if (completed) require(!priv.flags, "completed worker clears shared flag");

            reset(kind, completed);
            ret = mxl862xx_api_wrap(&priv, SYS_MISC_FW_UPDATE, &data, sizeof(data), true, false);
            require(ret == (kind ? -EIO : 0), "other commands retain their errno contract");

            if (kind != 4) {
                reset(kind, completed);
                ret = mxl862xx_api_wrap(&priv, INT_GPHY_WRITE, &data, sizeof(data), false, false);
                require(ret == (kind ? -EIO : 0), "write commands retain their errno contract");
            }
        }
    }
    puts("PASS: host/firmware CRC6/CRC16 keep per-call results and shutdown notifications");
    return 0;
}
