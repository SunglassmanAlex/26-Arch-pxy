# xv6 boot smoke images

These images are used by the Lab+ xv6 boot smoke target:

```bash
make test-labplus-xv6boot-check
```

The kernel image was built from MIT xv6-riscv for a no-RVC core:

```text
-march=rv64ima_zicsr_zifencei -mabi=lp64
```

The smoke image is intentionally trimmed for RTL simulation speed and current
platform coverage: `PHYSTOP` is reduced to 16 MiB, allocator poison fills are
disabled, and UART TX uses synchronous polling. Virtio disk requests use xv6's
normal sleep/wakeup path and are completed through PLIC source 1 interrupts.
It is meant to verify that the CPU, Sv39, S-mode trap path, PLIC/UART, and
virtio block model can boot xv6 to the shell banner (`init: starting sh`).
