# LC-5200b — Superscalar Pipelined Processor

The extra-credit project for **CS 2200 (Systems and Networks)** at Georgia Tech: a
"superscalar" implementation of the LC-5200b ISA. The baseline is a conventional
5-stage pipeline; this design pushes past one instruction per cycle with a single
ALU by exploiting instruction-level parallelism at fetch and decode time.

## Architecture

- **2-wide fetch** into a 4-instruction window (`fetch.sv`), split from a decoupled
  backend by a fetch buffer.
- **Macro-op fusion** (`fusion.sv`): pairs of adjacent instructions are merged into a
  single control word, so two operations retire together. The fused control words are
  generated offline by a Z3-based ROM generator (`generator.py`) and burned into a
  65536-entry microcode ROM.
- **Single ALU** shared by the fused pair (`alu.sv`, `execute.sv`) — no second
  execution unit.
- **Branch prediction**: a BTB (`btb.sv`, plus `btb32.sv` / `btb88.sv` variants) and a
  return-address stack (`ras.sv`), with a backward-taken/forward-not-taken default for
  misses.
- **L1 instruction cache** in front of the single-ported instruction RAM
  (`mmu.sv`, `bank.sv`) so the wider frontend can feed 2-wide fetch.
- **Microcoded decode** (`decode.sv`) with an AGU folded into the decode stage, a
  dual-ported register file (`dprf.sv`), and a hazard/stall unit in `pipeline.sv`.

The design is written in SystemVerilog, transpiled to Verilog for simulation and for
CircuitSim export.

## Known gaps

`verilog/l0cache.sv` and `verilog/memctrl.sv` are the data-side memory system I designed
but never finished wiring in: a unified memory controller that arbitrates an
Execute-stage speculative read against a Memory-stage definitive read/write over the
single DMEM port, a 16-set/4-way L0 cache with two combinational read ports, and a
4-deep write buffer to drain stores in the background.

They are **not part of the build** — the Makefile lists its components explicitly
(`COMPONENTS`), so these files are never compiled — and they will not compile as-is:
they reference `cache_req_t` / `cache_resp_t`, types I designed but never added to
`types.sv`. The pipeline runs on the flat single-ported DMEM it always used; the hooks
for the early-load path are plumbed through decode and tied off there.

Finishing a module and wiring it into a working pipeline are two different projects, and
I only had time for the first one. The numbers below are the pipeline as shipped.

## Results

Measured with `make stats` (cycles include the whole run through HALT):

| Program | Cycles | Instructions | CPI | Speedup vs. baseline |
| ------- | -----: | -----------: | --: | -------------------: |
| `pow`    | 1246 | 1223 | 1.019 | 6.52x |
| `fib`    | 4609 | 5150 | 0.895 | 7.01x |
| `TwoSum` | 1880 | 1882 | 0.999 | 6.55x |
| **Aggregate** | **7735** | **8255** | **0.937** | **6.82x** |

Aggregate CPI is **0.937** — below 1.0, i.e. more than one instruction retires per
cycle on average, which is what makes the design genuinely superscalar rather than
just deeply pipelined. Baselines are the original non-pipelined LC-5200b runs
(pow 8129, fib 32312, TwoSum 12314 cycles, as recorded in `progression.txt`).

`progression.txt` keeps the full narrative of the attempts that led here: the 5-stage
start, branch policy changes, BTB experiments, the move to macro-op fusion, the
CircuitSim size limits, and the L1 I-cache fix.

## Building and running

Everything lives under `extra/` (the project kept its original path so the Makefile's
relative paths — `../assembly/*.hex`, `./build/*` — continue to work):

```
extra/
├── assembly/   assembler, ISA definition, test programs (pow, fib, TwoSum)
├── sim/        CircuitSim subcircuit files
├── verilog/    the CPU: SystemVerilog source, Makefile, ROM/compiler tooling
├── LC-5200b.sim
├── EC Project.pdf
└── progression.txt
```

### Quick path: simulation statistics

```sh
cd extra/verilog
make stats
```

This transpiles the SystemVerilog, builds the microcode ROM, compiles the testbench
with Icarus Verilog, and runs `pow`, `fib`, and `TwoSum`, printing per-program CPI and
speedup plus the aggregate line.

Requirements for `make stats` alone:

- `iverilog` / `vvp` (Icarus Verilog)
- `sv2v` (SystemVerilog → Verilog, produces `build/design.v`)
- `python3` with **Z3** (`generator.py` synthesizes the fusion ROM and writes
  `build/merged_rom.hex`)

The assembler's `.hex` ROM images for the three benchmarks are generated artifacts and
are not tracked, so produce them once before the first `make stats`:

```sh
cd extra/assembly
for p in pow fib TwoSum; do python3 assembler.py $p.s -i LC-5200b.isa; done
```

A note on `sv2v`: distro packages are linked against a specific GHC version, so after a
GHC upgrade they can fail with `libHSvector-...-ghc9.6.6.so: cannot open shared object
file`. That's a stale install, not a problem with this code — reinstall `sv2v`.

The `Results` table above was verified by recompiling the generated `design.v` with
Icarus Verilog and reproducing every cycle count exactly (pow 1246/1223, fib 4609/5150,
TwoSum 1880/1882).

### Full flow (synthesis and CircuitSim)

```sh
cd extra/verilog
make test      # iverilog + vvp testbench
make netlist   # Yosys synthesis -> build/netlist.json
make sim       # compiler.py renders the netlist as a CircuitSim .sim file
make runsim    # opens it in CircuitSim
```

The full flow additionally needs **Yosys**, **CircuitSim**, and **Z3**. `make clean`
removes `build/`, the compiled simulator, and generated `.vcd`/`.sim` output.

## Provenance

This repository is a **history-filtered subset** of the original
[`Mr-Thack/cs2200`](https://github.com/Mr-Thack/cs2200) repository, containing only the
`extra/` extra-credit project. The other course projects that shared that repo were
removed from every commit with `git filter-repo --path extra/`, so no paths, files, or
blobs from them remain in this repository's history. Build artifacts that had been
committed by accident (`build/` outputs, `*.vcd`, Yosys netlist JSON, `a.out`) were
stripped from history as well; aside from those, the `extra/` tree at `HEAD` is
byte-identical to the `extra/` tree at the original repo's final commit.

Course-provided scaffolding (`LC-5200b.sim`, the ISA definition and simulator under
`assembly/`, the CircuitSim primitives in `sim/`) is included as it was distributed
with the assignment.
