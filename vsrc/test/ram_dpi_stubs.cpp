#include <cstdint>

static uint64_t ram[1 << 16];

extern "C" int get_switch() {
    return 0;
}

extern "C" uint64_t ram_read_helper(uint8_t en, uint64_t rIdx) {
    if (!en) {
        return 0;
    }
    return ram[rIdx & ((1 << 16) - 1)];
}

extern "C" void ram_write_helper(uint64_t wIdx, uint64_t wdata, uint64_t wmask, uint8_t wen) {
    if (!wen) {
        return;
    }
    uint64_t idx = wIdx & ((1 << 16) - 1);
    ram[idx] = (ram[idx] & ~wmask) | (wdata & wmask);
}
