#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define MII_BUS_ID_SIZE 32
#define KBUILD_MODNAME "mxl862xx"
#define MII_PHYSID1 2
#define MII_PHYSID2 3
#define MXL862XX_FLAG_CRC_ERR 0
#define INT_GPHY_READ 0x1801
#define INT_GPHY_WRITE 0x1802
#define cpu_to_le16(x) (x)
#define le16_to_cpu(x) (x)
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x, value) ((x) = (value))
typedef uint16_t u16;
struct device_node { int unused; };
struct device { struct device_node *of_node; };
struct mxl862xx_priv { bool phy_initializing; unsigned long flags; };
struct dsa_switch { struct mxl862xx_priv *priv; struct device *dev; unsigned int phys_mii_mask; };
struct mii_bus {
    struct mxl862xx_priv *priv;
    const char *name;
    char id[MII_BUS_ID_SIZE];
    int (*read)(struct mii_bus *, int, int);
    int (*write)(struct mii_bus *, int, int, u16);
    int (*read_c45)(struct mii_bus *, int, int, int);
    int (*write_c45)(struct mii_bus *, int, int, int, u16);
    struct device *parent;
    unsigned int phy_mask;
    int mdio_lock;
};
struct mdio_relay_data { int phy, mmd; u16 reg, data; };
static struct mii_bus bus;
static struct device_node node;
static unsigned int reads[4], writes, sleeps, elapsed;
static int failures, fail_reg, failure_errno, register_error;
static bool discovered[4], crc_failure, complete_crc_worker;

static void require(bool condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}
static inline void msleep(unsigned int ms) { sleeps++; elapsed += ms; }
static void mutex_lock(int *lock) { require(!*lock, "double lock"); *lock = 1; }
static void mutex_unlock(int *lock) { require(*lock, "unlock without lock"); *lock = 0; }
static int api_read(struct mxl862xx_priv *priv, int cmd, struct mdio_relay_data *p)
{
    require(cmd == INT_GPHY_READ && p->phy >= 0 && p->phy < 4, "unexpected read");
    reads[p->phy]++;
    if (p->phy == 0 && p->reg == fail_reg && failures) {
        if (failures > 0)
            failures--;
        if (crc_failure) {
            priv->flags |= 1UL << MXL862XX_FLAG_CRC_ERR;
            if (complete_crc_worker) priv->flags = 0;
            return -EBADMSG;
        }
        return failure_errno;
    }
    p->data = p->reg == MII_PHYSID1 ? 0xc133 : 0x5528;
    return 0;
}
static int api_write(struct mxl862xx_priv *priv, int cmd, struct mdio_relay_data *p)
{
    (void)priv; (void)p;
    require(cmd == INT_GPHY_WRITE, "unexpected write");
    writes++;
    return -EIO;
}
#define MXL862XX_API_READ(priv, cmd, param) api_read(priv, cmd, &(param))
#define MXL862XX_API_WRITE(priv, cmd, param) api_write(priv, cmd, &(param))
static struct mii_bus *devm_mdiobus_alloc(struct device *dev) { (void)dev; return &bus; }
static const char *dev_name(struct device *dev) { (void)dev; return "mdio-bus:10"; }
static struct device_node *of_get_child_by_name(struct device_node *n, const char *name)
{ (void)n; (void)name; return &node; }
static void of_node_put(struct device_node *n) { (void)n; }
static int mxl862xx_phy_write_c45_mii_bus(struct mii_bus *b, int a, int d, int r, u16 v)
{ (void)b; (void)a; (void)d; (void)r; (void)v; return 0; }
static int devm_of_mdiobus_register(struct device *dev, struct mii_bus *b, struct device_node *n)
{
    (void)dev; (void)n;
    if (register_error)
        return register_error;
    b->mdio_lock = 0;
    for (int addr = 0; addr < 4; addr++) {
        mutex_lock(&b->mdio_lock);
        int hi = b->read(b, addr, MII_PHYSID1);
        int lo = hi < 0 ? hi : b->read(b, addr, MII_PHYSID2);
        mutex_unlock(&b->mdio_lock);
        discovered[addr] = hi == 0xc133 && lo == 0x5528;
    }
    return 0;
}
#include "driver.inc"

static void reset(struct mxl862xx_priv *priv, int count, int reg)
{
    *priv = (struct mxl862xx_priv){0};
    bus = (struct mii_bus){.mdio_lock = -1};
    for (int i = 0; i < 4; i++) { reads[i] = 0; discovered[i] = false; }
    sleeps = elapsed = writes = 0;
    failures = count; fail_reg = reg; failure_errno = -EIO;
    register_error = 0; crc_failure = complete_crc_worker = false;
}
int main(void)
{
    struct mxl862xx_priv priv = {0};
    struct device dev = {0};
    struct dsa_switch ds = {.priv = &priv, .dev = &dev};
    for (int reg = MII_PHYSID1; reg <= MII_PHYSID2; reg++) {
        for (int count = 0; count <= 2; count++) {
            reset(&priv, count, reg);
            require(mxl862xx_setup_mdio(&ds) == 0, "registration succeeds");
            require(discovered[0], "transient PHY identity read must recover");
            require(!priv.phy_initializing, "initialization scope must end");
            require(reads[0] == (unsigned int)(2 + count), "only failed reads repeat");
            require(sleeps == (unsigned int)count && elapsed == 100U * count, "retry delay bound");
            for (int i = 1; i < 4; i++)
                require(discovered[i] && reads[i] == 2, "other PHYs unaffected");
            require(writes == 0, "discovery must not write PHYs");
        }
        reset(&priv, -1, reg);
        require(mxl862xx_setup_mdio(&ds) == 0, "missing PHY must not abort other ports");
        require(!discovered[0] && sleeps == 2 && elapsed == 200, "persistent error is bounded");
        require(reads[0] == (unsigned int)(3 + (reg == MII_PHYSID2)), "at most three attempts");
        for (int i = 1; i < 4; i++) require(discovered[i], "preserve other ports");
    }
    for (int completed = 0; completed <= 1; completed++) {
        reset(&priv, -1, MII_PHYSID1);
        crc_failure = true;
        complete_crc_worker = completed;
        require(mxl862xx_setup_mdio(&ds) == 0 && reads[0] == 1 && sleeps == 0, "CRC errors are not retried");
        require(bus.read(&bus, 0, MII_PHYSID1) == -EIO, "C22 CRC keeps PHYLIB errno");
        require(bus.read_c45(&bus, 0, 1, MII_PHYSID1) == -EIO, "C45 CRC keeps PHYLIB errno");
        for (int i = 1; i < 4; i++) require(discovered[i], "CRC failure does not abort other PHY discovery");
    }
    reset(&priv, -1, MII_PHYSID1);
    failure_errno = -EBUSY;
    require(mxl862xx_setup_mdio(&ds) == 0 && reads[0] == 1 && sleeps == 0, "non-I/O errors are not retried");
    reset(&priv, 0, MII_PHYSID1);
    require(mxl862xx_setup_mdio(&ds) == 0, "normal setup");
    failures = -1;
    unsigned int before = reads[0];
    require(bus.read(&bus, 0, MII_PHYSID1) == -EIO && reads[0] == before + 1 && sleeps == 0, "runtime reads are not retried");
    priv.phy_initializing = true;
    fail_reg = 1;
    before = reads[0];
    require(bus.read(&bus, 0, 1) == -EIO && reads[0] == before + 1 && sleeps == 0, "non-identity reads are not retried");
    require(bus.write(&bus, 0, 0, 0) == -EIO && writes == 1 && sleeps == 0, "writes are not retried");
    reset(&priv, 0, MII_PHYSID1);
    register_error = -ENOMEM;
    require(mxl862xx_setup_mdio(&ds) == -ENOMEM && !priv.phy_initializing, "failed registration clears scope");
    puts("PASS: PHY ID transient/persistent failure, sibling ports, CRC, runtime and write boundaries");
    return 0;
}
