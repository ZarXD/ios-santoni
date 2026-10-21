#!/bin/bash
# dxb runs patches/*.sh after applying all patches/*.patch.
# riva (MSM8917): stage bsd/dev/sweet_mmc.c + register mmcroot0 root device.

[[ "${MACHINE_CONFIG:-}" == SANTONI ]] || exit 0

python3 - << 'PY'
from pathlib import Path
import re

# 1) bsd/conf/files: register sweet_mmc.c
f = Path('bsd/conf/files')
t = f.read_text()
if 'bsd/dev/sweet_mmc.c' not in t:
    if 'bsd/dev/sweet_ufs.c' in t:
        t = t.replace('bsd/dev/sweet_ufs.c\t\t\tstandard\n',
                      'bsd/dev/sweet_ufs.c\t\t\tstandard\nbsd/dev/sweet_mmc.c\t\t\tstandard\n', 1)
    else:
        t += 'bsd/dev/sweet_mmc.c\t\t\tstandard\n'
    f.write_text(t)
    print('riva: registered sweet_mmc.c in bsd/conf/files')

# 2) IOKitBSDInit.cpp: rd=mmcroot0 branch right after UFS root block
f = Path('iokit/bsddev/IOKitBSDInit.cpp')
t = f.read_text()
if 'sweet_mmc_rootdev' not in t:
    anchor = re.search(r'#endif\n\s*//\s*\n\s*//\tNow check if we are trying to root on a memory device', t)
    if anchor:
        block = (
            '#endif\n'
            '#if defined(ARM64_BOARD_CONFIG_SWEET)\n'
            '//\n'
            '//\tSWEET: root on eMMC (riva, bsd/dev/sweet_mmc.c)\n'
            '//\n'
            '\tif (strcmp(rdBootVar, "mmcroot0") == 0) {\n'
            '\t\textern int sweet_mmc_rootdev(dev_t *dev);\n'
            '\t\tOSSafeReleaseNULL(matching);\n'
            '\t\tint mmc_error = sweet_mmc_rootdev(root);\n'
            '\t\tif (mmc_error) {\n'
            '\t\t\tpanic("IOFindBSDRoot: SWEET eMMC root %s unavailable: %d", rdBootVar, mmc_error);\n'
            '\t\t}\n'
            '\t\tstrlcpy(rootName, rdBootVar, rootNameSize);\n'
            '\t\tIOLog("BSD root: %s, major %d, minor %d\\n", rootName, major(*root), minor(*root));\n'
            '\t\t*oflags = 0;\n'
            '\t\tgoto iofrootx;\n'
            '\t}\n'
            '#endif\n'
        )
        t = t[:anchor.start()] + block + t[anchor.start():]
        f.write_text(t)
        print('riva: added rd=mmcroot0 branch to IOFindBSDRoot')
    else:
        print('riva: IOKitBSDInit anchor not found; will patch later')
PY

# 3) Driver source: write bsd/dev/sweet_mmc.c if missing
if [ ! -f bsd/dev/sweet_mmc.c ]; then
  cat > bsd/dev/sweet_mmc.c << 'CCEOF'
/*
 * SWEET internal eMMC root device (riva/MSM8917, polled SDHCI).
 */
#if defined(ARM64_BOARD_CONFIG_SWEET)
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/buf.h>
#include <sys/conf.h>
#include <sys/disk.h>
#include <sys/errno.h>
#include <sys/proc.h>
#include <sys/uio.h>
#include <miscfs/devfs/devfs.h>
#include <kern/locks.h>
#include <kern/clock.h>
#include <machine/machine_routines.h>
#include <arm/caches_internal.h>
#include <vm/pmap.h>
#include <vm/vm_kern.h>
#include <pexpert/pexpert.h>
#include <pexpert/device_tree.h>
#include <libkern/libkern.h>

extern ppnum_t pmap_find_phys(pmap_t pmap, addr64_t va);
extern vm_offset_t ml_io_map(vm_offset_t phys_addr, vm_size_t size);

#define SDHCI_DMA_ADDRESS   0x00
#define SDHCI_BLOCK_SIZE    0x04
#define SDHCI_BLOCK_COUNT   0x06
#define SDHCI_ARGUMENT      0x08
#define SDHCI_TRANSFER_MODE 0x0C
#define SDHCI_COMMAND       0x0E
#define SDHCI_RESPONSE_0    0x10
#define SDHCI_RESPONSE_1    0x14
#define SDHCI_RESPONSE_2    0x18
#define SDHCI_RESPONSE_3    0x1C
#define SDHCI_BUFFER        0x20
#define SDHCI_PRESENT_STATE 0x24
#define SDHCI_HOST_CONTROL  0x28
#define SDHCI_POWER_CONTROL 0x29
#define SDHCI_CLOCK_CONTROL 0x2C
#define SDHCI_TIMEOUT_CONTROL 0x2E
#define SDHCI_SOFTWARE_RESET 0x2F
#define SDHCI_INT_STATUS    0x30
#define SDHCI_INT_ENABLE    0x34
#define SDHCI_SIGNAL_ENABLE 0x38
#define SDHCI_HOST_VERSION  0xFE

#define SDHCI_CMD_INHIBIT   (1u << 0)
#define SDHCI_DATA_INHIBIT  (1u << 1)
#define SDHCI_CARD_PRESENT  (1u << 16)
#define SDHCI_INT_RESPONSE  (1u << 0)
#define SDHCI_INT_DATA_END  (1u << 1)
#define SDHCI_INT_ERROR     (1u << 15)

#define MMC_BLOCK   512u
#define BOUNCE_SIZE (1u << 20)
#define CMD_TIMEOUT_NS (5ull * NSEC_PER_SEC)

static struct {
    vm_offset_t regs;
    vm_offset_t bounce;
    uint64_t bounce_pa;
    uint16_t rca;
    bool block_addr;
    uint64_t first_block, nblocks;
    uint32_t secsize;
    bool writable;
    int bmajor, cmajor;
    dev_t bdev;
    bool ready;
} sm;

static LCK_GRP_DECLARE(sweet_mmc_grp, "sweet_mmc");
static LCK_MTX_DECLARE(sweet_mmc_lock, &sweet_mmc_grp);

static inline uint32_t mmc_rd32(uint32_t off) { return *(volatile uint32_t *)(sm.regs + off); }
static inline uint16_t mmc_rd16(uint32_t off) { return *(volatile uint16_t *)(sm.regs + off); }
static inline uint8_t  mmc_rd8 (uint32_t off) { return *(volatile uint8_t  *)(sm.regs + off); }
static inline void mmc_wr32(uint32_t off, uint32_t v) { *(volatile uint32_t *)(sm.regs + off) = v; }
static inline void mmc_wr16(uint32_t off, uint16_t v) { *(volatile uint16_t *)(sm.regs + off) = v; }
static inline void mmc_wr8 (uint32_t off, uint8_t  v) { *(volatile uint8_t  *)(sm.regs + off) = v; }

static void mmc_flush_cache(uint32_t off, uint32_t len)
{ flush_dcache64((addr64_t)(sm.bounce_pa + off), len, TRUE); }

static int mmc_wait_ready(void)
{
    uint64_t deadline;
    nanoseconds_to_absolutetime(CMD_TIMEOUT_NS, &deadline);
    deadline += mach_absolute_time();
    while (mmc_rd32(SDHCI_PRESENT_STATE) & (SDHCI_CMD_INHIBIT | SDHCI_DATA_INHIBIT)) {
        if (mach_absolute_time() > deadline) {
            printf("SWEET MMC: controller busy timeout\n");
            return ETIMEDOUT;
        }
        delay(1);
    }
    return 0;
}

static int mmc_cmd(uint8_t cmd, uint32_t arg, uint16_t xfer_mode,
                   uint32_t *resp, int resp_len)
{
    int err = mmc_wait_ready();
    if (err) return err;
    uint16_t cmd_flags = ((uint16_t)cmd << 8);
    if (resp_len == 0) cmd_flags |= 0x00;
    else if (resp_len == 136) cmd_flags |= 0x01;
    else if (cmd == 5 || cmd == 52 || cmd == 53) cmd_flags |= 0x1A;
    else cmd_flags |= 0x02;
    if (cmd == 17 || cmd == 18 || cmd == 24 || cmd == 25) cmd_flags |= (1u << 5);
    mmc_wr16(SDHCI_INT_STATUS, 0xFFFF);
    mmc_wr32(SDHCI_ARGUMENT, arg);
    if (xfer_mode) mmc_wr16(SDHCI_TRANSFER_MODE, xfer_mode);
    mmc_wr16(SDHCI_COMMAND, cmd_flags);
    uint64_t deadline;
    nanoseconds_to_absolutetime(CMD_TIMEOUT_NS, &deadline);
    deadline += mach_absolute_time();
    uint16_t sts;
    while (!((sts = mmc_rd16(SDHCI_INT_STATUS)) & (SDHCI_INT_RESPONSE | SDHCI_INT_ERROR))) {
        if (mach_absolute_time() > deadline) {
            printf("SWEET MMC: CMD%u timeout\n", cmd);
            return ETIMEDOUT;
        }
        delay(1);
    }
    if (sts & SDHCI_INT_ERROR) {
        printf("SWEET MMC: CMD%u error 0x%x\n", cmd, sts);
        return EIO;
    }
    if (resp && resp_len > 0) {
        if (resp_len == 136) {
            resp[3] = mmc_rd32(SDHCI_RESPONSE_0);
            resp[2] = mmc_rd32(SDHCI_RESPONSE_1);
            resp[1] = mmc_rd32(SDHCI_RESPONSE_2);
            resp[0] = mmc_rd32(SDHCI_RESPONSE_3);
        } else {
            resp[0] = mmc_rd32(SDHCI_RESPONSE_0);
        }
    }
    mmc_wr16(SDHCI_INT_STATUS, SDHCI_INT_RESPONSE);
    return 0;
}

static int mmc_pio_read(uint32_t blocks)
{
    uint8_t *dst = (uint8_t *)sm.bounce;
    for (uint32_t b = 0; b < blocks; b++) {
        uint64_t deadline;
        nanoseconds_to_absolutetime(CMD_TIMEOUT_NS, &deadline);
        deadline += mach_absolute_time();
        while (!(mmc_rd16(SDHCI_INT_STATUS) & SDHCI_INT_DATA_END)) {
            if (mach_absolute_time() > deadline) {
                printf("SWEET MMC: PIO read timeout\n");
                return ETIMEDOUT;
            }
            delay(1);
        }
        for (uint32_t i = 0; i < MMC_BLOCK / 4; i++)
            *(uint32_t *)(dst + b * MMC_BLOCK + i * 4) = mmc_rd32(SDHCI_BUFFER);
        mmc_wr16(SDHCI_INT_STATUS, SDHCI_INT_DATA_END);
    }
    return 0;
}

static int mmc_pio_write(uint32_t blocks)
{
    uint8_t *src = (uint8_t *)sm.bounce;
    for (uint32_t b = 0; b < blocks; b++) {
        uint64_t deadline;
        nanoseconds_to_absolutetime(CMD_TIMEOUT_NS, &deadline);
        deadline += mach_absolute_time();
        while (!(mmc_rd16(SDHCI_INT_STATUS) & SDHCI_INT_DATA_END)) {
            if (mach_absolute_time() > deadline) {
                printf("SWEET MMC: PIO write timeout\n");
                return ETIMEDOUT;
            }
            delay(1);
        }
        for (uint32_t i = 0; i < MMC_BLOCK / 4; i++)
            mmc_wr32(SDHCI_BUFFER, *(uint32_t *)(src + b * MMC_BLOCK + i * 4));
        mmc_wr16(SDHCI_INT_STATUS, SDHCI_INT_DATA_END);
    }
    return 0;
}

static int mmc_read_blocks(uint64_t lba, uint32_t count)
{
    if (count == 0 || count > BOUNCE_SIZE / MMC_BLOCK)
        return EINVAL;
    uint32_t addr = sm.block_addr ? (uint32_t)lba : (uint32_t)(lba * MMC_BLOCK);
    uint16_t xfer = (1u << 4) |
        (count > 1 ? (1u << 5) | (1u << 2) | (1u << 1) : (1u << 4));
    mmc_wr16(SDHCI_BLOCK_SIZE, MMC_BLOCK);
    mmc_wr16(SDHCI_BLOCK_COUNT, count);
    int err = mmc_cmd(count > 1 ? 18 : 17, addr, xfer, NULL, 48);
    if (!err) err = mmc_pio_read(count);
    if (!err && count > 1) mmc_cmd(12, 0, 0, NULL, 48);
    mmc_flush_cache(0, count * MMC_BLOCK);
    return err;
}

static int mmc_write_blocks(uint64_t lba, uint32_t count)
{
    if (!sm.writable || count == 0 || count > BOUNCE_SIZE / MMC_BLOCK ||
        lba < sm.first_block || lba - sm.first_block >= sm.nblocks ||
        count > sm.nblocks - (lba - sm.first_block)) {
        printf("SWEET MMC: refusing write of %u blocks at 0x%llx\n", count, lba);
        return EPERM;
    }
    mmc_flush_cache(0, count * MMC_BLOCK);
    uint32_t addr = sm.block_addr ? (uint32_t)lba : (uint32_t)(lba * MMC_BLOCK);
    uint16_t xfer = (count > 1 ? (1u << 5) | (1u << 2) | (1u << 1) : 0);
    mmc_wr16(SDHCI_BLOCK_SIZE, MMC_BLOCK);
    mmc_wr16(SDHCI_BLOCK_COUNT, count);
    int err = mmc_cmd(count > 1 ? 25 : 24, addr, xfer, NULL, 48);
    if (!err) err = mmc_pio_write(count);
    if (!err && count > 1) mmc_cmd(12, 0, 0, NULL, 48);
    return err;
}

static int mmc_sync_cache(void) { return 0; }

static int mmc_find_partition(const char *want)
{
    const uint8_t *b = (const uint8_t *)sm.bounce;
    int err = mmc_read_blocks(1, 1);
    if (err) return err;
    if (memcmp(b, "EFI PART", 8) != 0) {
        printf("SWEET MMC: no GPT\n");
        return ENXIO;
    }
    uint64_t entry_lba; uint32_t nent, esz;
    memcpy(&entry_lba, b + 72, 8);
    memcpy(&nent, b + 80, 4);
    memcpy(&esz, b + 84, 4);
    if (esz != 128 || nent == 0 || nent * esz > BOUNCE_SIZE) {
        printf("SWEET MMC: unsupported GPT entries %u x %u\n", nent, esz);
        return ENXIO;
    }
    err = mmc_read_blocks(entry_lba, (nent * esz + MMC_BLOCK - 1) / MMC_BLOCK);
    if (err) return err;
    for (uint32_t i = 0; i < nent; i++) {
        const uint8_t *e = b + i * esz;
        char name[37]; unsigned c;
        for (c = 0; c < 36; c++) {
            uint16_t ch = (uint16_t)(e[56 + 2*c] | e[57 + 2*c] << 8);
            if (ch == 0 || ch > 0x7f) break;
            name[c] = (char)ch;
        }
        name[c] = 0;
        if (strcmp(name, want) != 0) continue;
        uint64_t first, last;
        memcpy(&first, e + 32, 8);
        memcpy(&last, e + 40, 8);
        if (last < first) return ENXIO;
        sm.first_block = first;
        sm.nblocks = last - first + 1;
        return 0;
    }
    printf("SWEET MMC: no GPT partition named \"%s\"\n", want);
    return ENOENT;
}

static int mmc_init_card(void)
{
    int err = mmc_cmd(0, 0, 0, NULL, 0);
    if (err) return err;
    delay(10);
    uint32_t ocr = 0;
    for (int i = 0; i < 100; i++) {
        err = mmc_cmd(1, 0x40FF8000, 0, &ocr, 48);
        if (err) return err;
        if (ocr & (1u << 31)) break;
        delay(10);
    }
    if (!(ocr & (1u << 31))) {
        printf("SWEET MMC: card power-up failed\n");
        return ENXIO;
    }
    sm.block_addr = !!(ocr & (1u << 30));
    uint32_t cid[4];
    err = mmc_cmd(2, 0, 0, cid, 136);
    if (err) return err;
    err = mmc_cmd(3, 0x00010000, 0, NULL, 48);
    if (err) return err;
    sm.rca = 1;
    err = mmc_cmd(7, ((uint32_t)sm.rca << 16), 0, NULL, 48);
    if (err) return err;
    uint32_t csd[4];
    err = mmc_cmd(9, ((uint32_t)sm.rca << 16), 0, csd, 136);
    if (err) return err;
    err = mmc_cmd(16, MMC_BLOCK, 0, NULL, 48);
    return err;
}

static int sweet_mmc_open(__unused dev_t dev, int flags,
                          __unused int devtype, __unused struct proc *p)
{
    if (!sm.ready) return ENXIO;
    return ((flags & FWRITE) && !sm.writable) ? EROFS : 0;
}

static int sweet_mmc_close(__unused dev_t dev, __unused int flags,
                           __unused int devtype, __unused struct proc *p)
{ return 0; }

static void sweet_mmc_strategy(buf_t bp)
{
    int error = 0;
    caddr_t vaddr = NULL;
    uint64_t off = (uint64_t)buf_blkno(bp) * sm.secsize;
    uint32_t count = buf_count(bp);
    uint64_t part_bytes = sm.nblocks * MMC_BLOCK;
    bool rd = buf_flags(bp) & B_READ;
    buf_setresid(bp, count);
    if (!rd && !sm.writable) { error = EROFS; goto done; }
    if (off > part_bytes || count > part_bytes - off) { error = EINVAL; goto done; }
    if (count == 0) goto done;
    if (buf_map(bp, &vaddr)) { error = EIO; goto done; }
    lck_mtx_lock(&sweet_mmc_lock);
    for (uint32_t done = 0; done < count;) {
        uint64_t pos = off + done;
        uint64_t lba = pos / MMC_BLOCK;
        uint32_t skip = (uint32_t)(pos % MMC_BLOCK);
        uint32_t want = MIN(count - done, BOUNCE_SIZE - skip);
        uint32_t blocks = (skip + want + MMC_BLOCK - 1) / MMC_BLOCK;
        if (rd) {
            error = mmc_read_blocks(sm.first_block + lba, blocks);
            if (!error) memcpy(vaddr + done, (const char *)sm.bounce + skip, want);
        } else {
            if (skip || (want % MMC_BLOCK)) error = mmc_read_blocks(sm.first_block + lba, blocks);
            if (!error) {
                memcpy((char *)sm.bounce + skip, vaddr + done, want);
                error = mmc_write_blocks(sm.first_block + lba, blocks);
            }
        }
        if (error) break;
        done += want;
        buf_setresid(bp, count - done);
    }
    lck_mtx_unlock(&sweet_mmc_lock);
    buf_unmap(bp);
done:
    if (error) buf_seterror(bp, error);
    buf_biodone(bp);
}

static int sweet_mmc_ioctl(__unused dev_t dev, u_long cmd, caddr_t data,
                           __unused int flag, __unused struct proc *p,
                           int is_char)
{
    uint32_t *f = (uint32_t *)data;
    uint64_t *o = (uint64_t *)data;
    switch (cmd) {
    case DKIOCGETBLOCKSIZE: *f = sm.secsize; return 0;
    case DKIOCSETBLOCKSIZE:
        if (is_char) return ENODEV;
        if (*f < DEV_BSIZE || *f > MMC_BLOCK || (*f & (*f - 1))) return EINVAL;
        sm.secsize = *f; return 0;
    case DKIOCGETPHYSICALBLOCKSIZE: *f = MMC_BLOCK; return 0;
    case DKIOCGETBLOCKCOUNT: *o = sm.nblocks * MMC_BLOCK / sm.secsize; return 0;
    case DKIOCISWRITABLE: *f = sm.writable; return 0;
    case DKIOCSYNCHRONIZE:
    case DKIOCSYNCHRONIZECACHE:
        if (!sm.writable) return 0;
        lck_mtx_lock(&sweet_mmc_lock);
        int err = mmc_sync_cache();
        lck_mtx_unlock(&sweet_mmc_lock);
        return err;
    case DKIOCGETMAXBLOCKCOUNTREAD: *o = BOUNCE_SIZE / sm.secsize; return 0;
    case DKIOCGETMAXBLOCKCOUNTWRITE: *o = sm.writable ? BOUNCE_SIZE / sm.secsize : 0; return 0;
    case DKIOCGETMAXSEGMENTCOUNTREAD:
    case DKIOCGETMAXSEGMENTCOUNTWRITE: *o = 1; return 0;
    default: return ENOTTY;
    }
}

static int sweet_mmc_bioctl(dev_t dev, u_long cmd, caddr_t data, int flag, struct proc *p)
{ return sweet_mmc_ioctl(dev, cmd, data, flag, p, 0); }
static int sweet_mmc_cioctl(dev_t dev, u_long cmd, caddr_t data, int flag, struct proc *p)
{ return sweet_mmc_ioctl(dev, cmd, data, flag, p, 1); }

static int sweet_mmc_psize(__unused dev_t dev)
{ return sm.ready ? (int)MIN(sm.nblocks * MMC_BLOCK / sm.secsize, INT_MAX) : -1; }

static int sweet_mmc_read(dev_t dev, struct uio *uio, __unused int ioflag)
{ return physio(sweet_mmc_strategy, NULL, dev, B_READ, minphys, uio, (int)sm.secsize); }

static int sweet_mmc_write(dev_t dev, struct uio *uio, __unused int ioflag)
{ if (!sm.writable) return EROFS; return physio(sweet_mmc_strategy,NULL,dev,B_WRITE,minphys,uio,(int)sm.secsize); }

static const struct bdevsw sweet_mmc_bdevsw = {
    .d_open = sweet_mmc_open,
    .d_close = sweet_mmc_close,
    .d_strategy = sweet_mmc_strategy,
    .d_ioctl = sweet_mmc_bioctl,
    .d_dump = eno_dump,
    .d_psize = sweet_mmc_psize,
    .d_type = D_DISK,
};

static const struct cdevsw sweet_mmc_cdevsw = {
    .d_open = sweet_mmc_open,
    .d_close = sweet_mmc_close,
    .d_read = sweet_mmc_read,
    .d_write = sweet_mmc_write,
    .d_ioctl = sweet_mmc_cioctl,
    .d_stop = eno_stop,
    .d_reset = eno_reset,
    .d_ttys = NULL,
    .d_select = eno_select,
    .d_mmap = eno_mmap,
    .d_strategy = eno_strat,
    .d_reserved_1 = eno_getc,
    .d_reserved_2 = eno_putc,
    .d_type = D_DISK,
};

static int sweet_mmc_init(void)
{
    DTEntry node; uintptr_t const *reg = NULL; unsigned int size = 0;
    char want[64] = "userdata"; int error; uint32_t rw = 0;
    if (SecureDTLookupEntry(NULL, "/sweet-mmc", &node) != kSuccess ||
        SecureDTGetProperty(node, "reg", (void const **)&reg, &size) != kSuccess ||
        size < 2 * sizeof(uintptr_t)) {
        printf("SWEET MMC: no /sweet-mmc node in device tree\n");
        return ENXIO;
    }
    PE_parse_boot_argn("mmcroot", want, sizeof(want));
    if (!PE_parse_boot_argn("mmcrw", &rw, sizeof(rw)))
        PE_parse_boot_argn("ufsrw", &rw, sizeof(rw));

    sm.regs = ml_io_map(reg[0], reg[1]);
    if (kmem_alloc_contig(kernel_map, &sm.bounce, BOUNCE_SIZE,
                         PAGE_MASK, 0, 0,
                         KMA_DATA | KMA_ZERO | KMA_PERMANENT,
                         VM_KERN_MEMORY_IOKIT) != KERN_SUCCESS) {
        printf("SWEET MMC: no contiguous bounce buffer\n");
        return ENOMEM;
    }
    ppnum_t pn = pmap_find_phys(kernel_pmap, (addr64_t)sm.bounce);
    if (!pn) return ENOMEM;
    sm.bounce_pa = ptoa_64(pn);
    sm.secsize = DEV_BSIZE;

    lck_mtx_lock(&sweet_mmc_lock);
    error = mmc_init_card();
    if (!error) error = mmc_find_partition(want);
    lck_mtx_unlock(&sweet_mmc_lock);
    if (error) return error;

    sm.writable = (rw != 0);
    sm.bmajor = bdevsw_add(-1, &sweet_mmc_bdevsw);
    if (sm.bmajor < 0) return ENXIO;
    sm.cmajor = cdevsw_add_with_bdev(-1, &sweet_mmc_cdevsw, sm.bmajor);
    if (sm.cmajor < 0) return ENXIO;
    sm.bdev = makedev(sm.bmajor, 0);
    devfs_make_node(sm.bdev, DEVFS_BLOCK, UID_ROOT, GID_OPERATOR, 0640, "mmcroot0");
    devfs_make_node(makedev(sm.cmajor, 0), DEVFS_CHAR, UID_ROOT, GID_OPERATOR, 0640, "rmmcroot0");
    sm.ready = true;
    printf("SWEET MMC: \"%s\": first block 0x%llx, %llu MiB, %s (eMMC %s-addressing)\n",
        want, sm.first_block, sm.nblocks * MMC_BLOCK >> 20,
        sm.writable ? "read-write" : "read-only",
        sm.block_addr ? "block" : "byte");
    return 0;
}

int sweet_mmc_rootdev(dev_t *dev);

int sweet_mmc_rootdev(dev_t *dev)
{
    if (!sm.ready) {
        int err = sweet_mmc_init();
        if (err) return err;
    }
    *dev = sm.bdev;
    return 0;
}
#endif /* ARM64_BOARD_CONFIG_SWEET */
CCEOF
fi

echo "riva emmc staged (SANTONI)"
exit 0
