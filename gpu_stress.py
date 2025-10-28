"""GPU stress and fragmentation utility.

This module provides a CLI tool that reproduces the heavy memory fragmentation
and compute pressure patterns that can destabilise Ada Lovelace GPUs such as
the RTX 4090.  It is an evolution of the simple script originally written for
RTX 3090 cards: the logic is now encapsulated in classes, exposes more
parameters, and performs a broader mix of allocation sizes and compute kernels
to sustain high power draw for prolonged periods of time.

Example
-------
```bash
python gpu_stress.py --hours 0.5 --target-mem-ratio 0.96 --device 0
```
"""

from __future__ import annotations

import argparse
import random
import threading
import time
from dataclasses import dataclass
from typing import Dict, Iterable, List, Sequence

import torch


def _bytes_to_elements(num_bytes: int, dtype: torch.dtype) -> int:
    """Return the number of elements that occupy ``num_bytes`` for ``dtype``."""

    itemsize = torch.tensor([], dtype=dtype).element_size()
    return max(1, num_bytes // itemsize)


@dataclass
class FragmentConfig:
    """Configuration options for the fragmentation workload."""

    target_mem_ratio: float = 0.95
    block_size_mib: Sequence[int] = (512, 256, 128, 64, 32, 16, 8, 4, 2, 1)
    min_block_mib: int = 1
    dtype: torch.dtype = torch.float32
    random_free_ratio: float = 0.15

    def block_size_bytes(self) -> List[int]:
        return [int(size * 1024 * 1024) for size in self.block_size_mib]


class MemoryFragmenter:
    """Allocate and randomly free tensors to create severe fragmentation."""

    def __init__(self, device: torch.device, config: FragmentConfig) -> None:
        self.device = device
        self.config = config
        self._tensors: List[torch.Tensor] = []

    def fragment(self) -> List[torch.Tensor]:
        torch.cuda.set_device(self.device)
        prop = torch.cuda.get_device_properties(self.device)
        total_mem = prop.total_memory
        target_mem = int(total_mem * self.config.target_mem_ratio)
        allocated = 0

        block_sizes = self.config.block_size_bytes()
        min_block = int(self.config.min_block_mib * 1024 * 1024)

        print(
            f"[GPU {self.device.index}] Fragmenting up to "
            f"{target_mem / (1024 ** 3):.2f} GiB "
            f"({self.config.target_mem_ratio * 100:.0f}% of {total_mem / (1024 ** 3):.2f} GiB)"
        )

        while allocated < target_mem and block_sizes:
            block_bytes = random.choice(block_sizes)
            if block_bytes < min_block:
                block_sizes.remove(block_bytes)
                continue

            elements = _bytes_to_elements(block_bytes, self.config.dtype)

            try:
                tensor = torch.empty(elements, dtype=self.config.dtype, device=self.device)
            except RuntimeError:
                # fall back to smaller allocations
                block_sizes = [size // 2 for size in block_sizes if size // 2 >= min_block]
                continue

            self._tensors.append(tensor)
            allocated += tensor.element_size() * tensor.nelement()

            if self._tensors and random.random() < self.config.random_free_ratio:
                idx = random.randrange(len(self._tensors))
                victim = self._tensors.pop(idx)
                allocated -= victim.element_size() * victim.nelement()

        print(
            f"[GPU {self.device.index}] Allocated ~{allocated / (1024 ** 3):.2f} GiB "
            f"across {len(self._tensors)} blocks"
        )
        return list(self._tensors)


def _run_power_kernel(x: torch.Tensor, y: torch.Tensor) -> None:
    """Execute a mix of dense operations to drive high power usage."""

    # Matrix multiplications dominate power consumption; pointwise ops keep the
    # allocator busy touching all fragments.
    for _ in range(3):
        z = torch.matmul(x, y)
        z.add_(0.125)
        z = torch.sin(z)
        _ = z.sum()


def _touch_fragmented_tensors(tensors: Iterable[torch.Tensor]) -> None:
    for tensor in tensors:
        tensor.add_(0.5)
        tensor.mul_(1.1)


def busy_loop_mem_power_fragment(device: torch.device, hours: float, config: FragmentConfig) -> None:
    """Fragment memory and run a heavy compute loop for ``hours`` hours."""

    torch.cuda.set_device(device)
    prop = torch.cuda.get_device_properties(device)
    print(f"[GPU {device.index}] Starting stress test on {prop.name}")

    fragmenter = MemoryFragmenter(device, config)
    tensors = fragmenter.fragment()

    size_mat = 6144 if prop.total_memory >= 20 * 1024 ** 3 else 4096
    x = torch.rand((size_mat, size_mat), device=device)
    y = torch.rand((size_mat, size_mat), device=device)

    start = time.time()
    target_sec = hours * 3600
    iteration = 0

    while True:
        _touch_fragmented_tensors(tensors)
        _run_power_kernel(x, y)

        iteration += 1
        if iteration % 8 == 0:
            torch.cuda.synchronize()
            elapsed = time.time() - start
            print(
                f"[GPU {device.index}] Elapsed {elapsed / 3600:.2f}h, "
                f"iteration {iteration}, max allocated {torch.cuda.max_memory_allocated() / (1024 ** 3):.2f} GiB"
            )
            if elapsed >= target_sec:
                print(f"[GPU {device.index}] Completed {hours:.2f}h stress test")
                break


def run_on_gpu(device_id: int, hours: float, config: FragmentConfig) -> None:
    device = torch.device(f"cuda:{device_id}")
    busy_loop_mem_power_fragment(device, hours, config)


def run_all_gpus(hours: float, config: FragmentConfig) -> None:
    threads: Dict[int, threading.Thread] = {}
    for device_id in range(torch.cuda.device_count()):
        thread = threading.Thread(target=run_on_gpu, args=(device_id, hours, config), daemon=True)
        thread.start()
        threads[device_id] = thread

    for thread in threads.values():
        thread.join()


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Stress GPUs with fragmentation and compute load.")
    parser.add_argument("--hours", type=float, required=True, help="Duration of the stress test in hours.")
    parser.add_argument("--device", type=int, help="Specific CUDA device id to stress.")
    parser.add_argument("--target-mem-ratio", type=float, default=0.95, help="Fraction of VRAM to occupy.")
    parser.add_argument(
        "--free-ratio",
        type=float,
        default=0.15,
        help="Probability of releasing a random block during fragmentation (0-1).",
    )
    parser.add_argument(
        "--min-block-mib",
        type=int,
        default=1,
        help="Minimum allocation granularity in MiB when fragmentation retries occur.",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> None:
    args = parse_args(argv)

    config = FragmentConfig(
        target_mem_ratio=args.target_mem_ratio,
        random_free_ratio=args.free_ratio,
        min_block_mib=args.min_block_mib,
    )

    if args.device is not None:
        if not (0 <= args.device < torch.cuda.device_count()):
            raise ValueError(f"Invalid GPU id {args.device}")
        run_on_gpu(args.device, args.hours, config)
    else:
        run_all_gpus(args.hours, config)


if __name__ == "__main__":
    main()
