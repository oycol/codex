# codex

## GPU stress utility

This repository now contains `gpu_stress.py`, a utility that fragments GPU
memory and executes heavy compute kernels designed to reproduce the instability
that can lead to a 4090 "掉卡" (driver reset / drop). Example usage:

```bash
python gpu_stress.py --hours 1.0 --target-mem-ratio 0.96 --device 0
```

Omit `--device` to stress every visible GPU concurrently. Use the optional
flags described via `python gpu_stress.py --help` to fine-tune the fragmentation
pattern when testing different cards.