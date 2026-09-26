# ARINC 429 Health-Aware Communication Controller
## Complete Project Overview & Workflow

---

## 📋 Project Description

This project implements a **Health-Aware ARINC 429 Communication Controller** - an avionic communication protocol verification and fault injection framework. The system detects and classifies communication health states using hardware fault injection testing and machine learning.

### Key Objectives
- ✅ Implement ARINC 429 transmitter (TX) and receiver (RX) modules in Verilog
- ✅ Integrate TX/RX with a central controller
- ✅ Generate synthetic fault injection dataset with health labels
- ✅ Train ML classifiers to predict communication health states
- ✅ Verify protocol compliance and fault detection capabilities

---

## 🏗️ System Architecture

### Core Components

#### 1. **RTL Modules** (Hardware Design)
- **arinc429_tx.v** - Transmitter Module
  - Serializes 32-bit words to ARINC 429 format
  - Implements odd parity calculation
  - Manages interword gaps and timing
  - Output: Serial bit stream (MSB→LSB)

- **arinc429_rx.v** - Receiver Module
  - Deserializes incoming bit stream
  - Synchronizes using 2-stage flip-flop
  - Reconstructs 32-bit words
  - Validates odd parity, flags errors

- **arinc429_controller.v** - Integration Controller
  - Multiplexes TX/RX signals
  - Supports loopback testing mode
  - Manages source selection (internal/external)
  - Coordinates TX→RX communication flow

#### 2. **Fault Injection Module** (Testbench)
- **arinc429_fault_injector.v**
  - Injects single-bit errors into TX→RX wire
  - Supports timeout/truncation faults
  - Tracks fault injection points for analysis
  - Used ONLY in simulation (non-synthesizable)

#### 3. **Testbench Framework** (Verification)
- **tb_arinc429_tx_review1_fix.v**
  - 9 regression tests for TX module
  - Validates timing, reset behavior, edge cases
  - Tests: RESET, NORMAL, MIXED, ALL_ZERO, ALL_ONE, etc.

- **tb_arinc429_rx_review1_fix.v**
  - 20 regression tests for RX module
  - Normal reception, parity validation, error detection
  - Tests corrupt words, timing, synchronization

- **tb_arinc429_controller_review1_fix.v**
  - 15 controller integration tests
  - Loopback scenarios, source switching
  - Full end-to-end communication verification

- **tb_arinc429_fault_injection.v** (Review-2 Corrected)
  - Comprehensive fault injection campaign
  - 4 test modes: baseline, directed, random, systematic
  - Generates ML dataset with health labels
  - 18 major defect fixes (FI-01 through FI-19)

---

## 📊 ARINC 429 Protocol Specification

| Parameter | Value | Notes |
|-----------|-------|-------|
| **Baud Rate** | 100 kbps | Standard avionics |
| **Word Length** | 32 bits | Label(8) + SDI(2) + Data(19) + SSM(2) + Parity(1) |
| **Parity Type** | Odd | XOR of all 32 bits = 1 |
| **Interword Gap** | 4 bits (40 µs) | Quiet bus between transmissions |
| **System Clock** | 50 MHz | 500 cycles per ARINC bit |
| **Idle State** | HIGH (1) | Bus at rest = all 1's |

### Bit Timing
- **Bit Duration**: 10 µs (500 clock cycles @ 50 MHz)
- **Word TX Time**: 320 µs (32 bits × 10 µs)
- **Gap Duration**: 40 µs (4 bits × 10 µs)
- **Total TX Cycle**: 360 µs (18,000 clock cycles)

---

## 🔄 Complete Workflow

### Phase 1: Baseline Verification ✅

#### Step 1: Unit Testing (Regressions)
```
TX Module Tests (9/9 PASS)
├── Reset behavior
├── Normal transmission
├── Edge cases (all 0s, all 1s, alternating)
├── Timing validation
└── State machine verification

RX Module Tests (20/20 PASS)
├── Normal reception
├── Parity validation
├── Error detection
├── Synchronization
└── Corrupted word handling

Controller Tests (15/15 PASS)
├── Loopback mode
├── External source switching
├── Source latching
└── Multi-transaction sequencing
```

#### Step 2: Baseline Fault Injection
- **Test Count**: 44 baseline tests (TX 9 + RX 20 + CTL 15)
- **Result**: 44/44 PASS
- **Key Finding**: All protocol requirements met, odd parity detection working

#### Step 3: Comprehensive Fault Campaign
- **Injection Types**: Single-bit errors, timeout faults, repeated errors
- **Fault Classes**:
  - Single-bit corruption (detected via parity)
  - Two-bit faults (undetectable - expected limitation)
  - Timeout/truncation (partial/no reception)
  - Bus idle (prolonged inactivity)
  - High error rates (window-level analysis)

- **Consistency Equations** (14 verified):
  ```
  E1: total_tests = passed + failed
  E2: faults_injected = detected + undetected + limitations + unresolved
  E3: parity_faults = parity_detected + parity_undetected + anomalies
  E4: two_bit_faults = two_bit_limitations
  E5-E14: Additional ledger equations for timeouts, FIFOs, labels, etc.
  ```

- **Result**: 226/226 tests PASS, all equations hold

---

### Phase 2: ML Dataset Generation

#### Step 1: Fault Injection Campaign (Simulation)
```
Simulation Run Modes:
├── MODE=0: Baseline (no injection)
├── MODE=1: Random fault injection (configurable seed/tests)
├── MODE=2: Directed systematic tests
└── CONFIG: SEED, TESTS, PROB, WINDOW, THRESH, TIMEOUT, IDLE, FDEPTH
```

#### Step 2: CSV Dataset Creation
**Output**: `arinc429_ml_dataset_seed<N>.csv`

**Row Types**:
- **Type 0**: Normal communication transactions
- **Type 1**: Window-level events (repeated errors, high-rate windows)
- **Type 2**: Anomaly events (timeout, bus idle)
- **Type 3**: Reset recovery events

**Health Labels** (9 + 1 unreliable):
- **0-8**: Specific fault/anomaly classes
  - 0: Normal operation
  - 1: Single-bit parity error (detected)
  - 2: Two-bit error (undetectable)
  - 3: Timeout fault
  - 4: Bus idle
  - 5: High error rate
  - 6: Repeated error pattern
  - 7: FIFO anomaly
  - 8: Invalid label
- **98**: Health unreliable (verification failed)

**Features** (11 behavioral):
- `parity_error`: Receiver detected parity fault
- `rx_word_mismatch`: Received data ≠ transmitted data
- `rx_valid`: Receiver produced valid output
- `tx_done`: Transmitter completed
- `idle_duration`: Bus quiet time
- `consecutive_error_count`: Back-to-back errors
- `error_rate_pct`: Errors / total × 100
- `repeat_count`: Repeated error instances
- `successful_transactions_between_errors`: Recovery metric
- `window_size`: Observation window (bits)
- `window_faulty`: Faults in window

---

### Phase 3: ML Model Training

#### Step 1: Data Preprocessing
```python
# Load dataset(s)
df = load_data(['arinc429_ml_dataset_seed1.csv', ...])

# Partition leakage guard: Group by transaction lineage
# Prevents data leak between train/test sets
gid = group_ids(df)  # rows grouped by row_type + transaction_id/window_id/event_id

# Handle missing values (-1 → median imputation)
df[FEATURES].replace(-1, np.nan)

# Select behavioral features (no identifiers, no ground-truth leakage)
X = df[FEATURES]  # 11 features
y = df['health_label']  # 9 classes + 98
```

#### Step 2: Train/Test Split (Group-Aware)
```python
# Group K-Fold or Group Shuffle Split
# Ensures entire transaction groups in either train or test, never both
splitter = GroupShuffleSplit(n_splits=5, test_size=0.2, random_state=42)
for train_idx, test_idx in splitter.split(X, groups=gid):
    X_train, X_test = X.iloc[train_idx], X.iloc[test_idx]
    y_train, y_test = y.iloc[train_idx], y.iloc[test_idx]
```

#### Step 3: Model Training (6 Classifiers)
```python
models = {
    'Decision Tree': DecisionTreeClassifier(max_depth=8),
    'Random Forest': RandomForestClassifier(n_estimators=300, max_depth=12),
    'Logistic Regression': LogisticRegression(C=1.0, max_iter=2000),
    'SVM (RBF)': SVC(kernel='rbf', C=10),
    'KNN': KNeighborsClassifier(n_neighbors=5),
    'Neural Network': MLPClassifier(hidden_layer_sizes=(32, 16)),
}

# Pipeline: Imputation → Scaling → Classifier
# Impute/scale fitted on train only, applied to test
pipeline = Pipeline([
    ('impute', SimpleImputer(strategy='median')),
    ('scale', StandardScaler()),
    ('clf', model),
])
```

#### Step 4: Evaluation Metrics
```
Per-Model Reporting:
├── Accuracy: (TP+TN) / Total
├── Balanced Accuracy: Mean recall per class
├── Macro F1: Harmonic mean of precision/recall
├── Classification Report: Per-class metrics
└── Confusion Matrix: Detailed predictions by class
```

---

## 🔧 Review-2 Corrections (18 Major Defects Fixed)

### Critical Fixes

| ID | Issue | Fix |
|----|-------|-----|
| **FI-01** | Reset scenarios had bitshift on 1-bit reg (no corruption) | Time-domain per-bit window mechanism |
| **FI-02** | Repeated-error tx_start issued while tx_busy high | Variant 3: Wait for tx_busy==0, verify T1 COMPLETED + T2 STARTED |
| **FI-03** | Dead conditions in timeout logic | Snapshot rx_valid_count AFTER engine, verify unchanged |
| **FI-04** | Incomplete timeout taxonomy | 4 sub-types: TRUNCATED_WORD, SILENT_BUS, NO_COMM, ARMED_NO_TX |
| **FI-05** | Limitations incremented on failed verification | Track in explicit *_unresolved buckets |
| **FI-06** | Repeated-error windows not in dataset | Add WINDOW row (row_type=1, fault_class=6) |
| **FI-07** | High-error-rate windows not in dataset | Add WINDOW row (row_type=1, fault_class=8) |
| **FI-08** | CSV column ambiguity | Separate: total_transactions / valid_transactions / errors_observed |
| **FI-09** | Coupled health/class columns | Independent: health_label ∈ {0..8, 98}; fault_class ∈ {0..8, 20, 99} |
| **FI-10** | Row identification ambiguous | Add: row_type + transaction_id + window_id + event_id + ref_transaction_id |
| **FI-11** | "REPEATED ERROR DETECTED" implied hardware | Changed to "PATTERN OBSERVED (analysis classification, NOT detection)" |
| **FI-12** | "HIGH ERROR RATE DETECTED" implied hardware | Changed to "CLASSIFIED (window-level ANALYSIS, not detection)" |
| **FI-13** | FIFO cases used cumulative counter | Verify per-case event delta |
| **FI-14** | Invalid-label records incomplete | Record: original_label, injected_label, label_supported=0 |
| **FI-15** | Bus-idle taxonomy missing control case | Add directed GAP_CONTROL test |
| **FI-16** | Window error rates incomplete | Add 0%, 10%, 28%, 30% (boundary), 50% |
| **FI-17** | Degenerate parameters not clamped | Add guards + full plusarg set |
| **FI-18** | Health unreliable not properly recorded | HEALTH_UNRELIABLE=98 ONLY on verification failure |
| **FI-19** | CSV integrity not audited | Audit every row: sample_id monotonic, fields in range, coherence checks |

### Verification Results
```
Icarus Verilog 12.0 - Verilog-2001 Mode
├── TX Regression:  9/9 PASS
├── RX Regression: 20/20 PASS
├── CTL Regression: 15/15 PASS (1 expected two-bit limitation)
├── MODE=0 (injection off): PASS, all 14 equations hold
├── MODE=2 (directed): PASS, all 14 equations hold
├── MODE=1 +TESTS=12 (random): PASS, all 14 equations hold
├── SEED=42 reproducibility: Byte-identical across runs
└── XSim compatibility: ✓ Verilog-2001, no SystemVerilog
```

---

## 📁 Project Structure

```
ARINC 429/
├── RTL/
│   ├── arinc429_tx.v              (Transmitter)
│   ├── arinc429_rx.v              (Receiver)
│   └── arinc429_controller.v      (Controller)
│
├── Testbench/
│   ├── tb_arinc429_tx_review1_fix.v
│   ├── tb_arinc429_rx_review1_fix.v
│   ├── tb_arinc429_controller_review1_fix.v
│   ├── arinc429_fault_injector.v  (Injection helper)
│   └── tb_arinc429_fault_injection.v (Review-2 Corrected)
│
├── Datasets/
│   ├── arinc429_ml_dataset_seed1.csv
│   ├── arinc429_ml_dataset_seed7.csv
│   └── arinc429_ml_dataset_seed42.csv
│
├── Scripts/
│   ├── ml_train_arinc429.py       (ML classifier training)
│   └── run_iverilog_recheck.sh    (Simulation runner)
│
├── Reports/
│   ├── PHASE1_COMPREHENSIVE_REPORT.md
│   ├── Phase_I_Report_ARINC429.docx
│   └── INTERACTIVE_ANALYZER_GUIDE.md
│
└── Documentation/
    ├── PROJECT_OVERVIEW.md        (This file)
    └── README.md                  (Quick start)
```

---

## 🚀 How to Run

### 1. Run Simulations (Icarus Verilog)
```bash
# Baseline tests only (MODE=0)
iverilog -g2009 -o tb_arinc429_fault_injection.vvp \
  arinc429_tx.v arinc429_rx.v arinc429_controller.v \
  arinc429_fault_injector.v tb_arinc429_fault_injection.v
vvp tb_arinc429_fault_injection.vvp +MODE=0

# Generate ML dataset (random faults, SEED=42)
vvp tb_arinc429_fault_injection.vvp +MODE=1 +SEED=42 +TESTS=1000

# Run directed tests (all suites)
vvp tb_arinc429_fault_injection.vvp +MODE=2

# Output: arinc429_ml_dataset_seed<N>.csv
```

### 2. Train ML Models
```bash
python3 ml_train_arinc429.py arinc429_ml_dataset_seed1.csv

# Output: Per-model accuracy, balanced accuracy, F1, confusion matrices
```

### 3. Vivado XSim Integration
```tcl
# Add simulation sources (RTL + Testbench)
add_files arinc429_tx.v arinc429_rx.v arinc429_controller.v
add_files -fileset sim_1 arinc429_fault_injector.v tb_arinc429_fault_injection.v

# Run with test parameters
launch_simulation -testplusarg +MODE=2 -testplusarg +SEED=1
# CSV appears in XSim working directory
```

---

## 📈 Expected Results

### Unit Testing
- **TX**: 9/9 PASS (timing, reset, edge cases)
- **RX**: 20/20 PASS (reception, parity, errors)
- **Controller**: 15/15 PASS (integration, loopback)
- **Total**: 44/44 PASS

### Fault Injection
- **Faults Injected**: ~226 (single-bit, timeout, etc.)
- **Detection Rate**: >99% for single-bit (odd parity)
- **Two-Bit Limitation**: Expected (odd parity masks 2-bit errors)
- **Dataset Size**: ~2000-5000 rows (seed-dependent)

### ML Model Performance
- **Accuracy**: 92-97% (model-dependent)
- **Balanced Accuracy**: 85-95%
- **Macro F1**: 80-90%
- **Best Model**: Random Forest or Neural Network

---

## 🔍 Key Design Decisions

1. **Odd Parity**: Detects single-bit errors; two-bit errors undetectable (architectural limit)
2. **Synchronization**: 2-stage flip-flop for metastability safety
3. **Sampling**: Midpoint-of-bit strategy (250 cycles into 500-cycle window)
4. **Fault Injection**: Time-domain per-bit window (not naive bitshift)
5. **ML Leakage Guard**: Group-aware splitting (entire transactions in train or test, never split)
6. **CSV Integrity**: Audit every row before write (sample_id monotonic, field ranges, coherence)

---

## 📚 References

- **ARINC 429 Specification**: 100 kbps data bus for civil aircraft
- **Odd Parity**: XOR of all 32 bits must equal 1
- **ML Methodology**: Scikit-learn, group-aware cross-validation, imputation + scaling
- **Simulators**: Icarus Verilog (open-source), Vivado XSim (commercial)

---

## ✅ Phase 1 Completion Status

- ✅ RTL Design (TX, RX, Controller)
- ✅ Unit Testing (44/44 PASS)
- ✅ Fault Injection (226/226 tests PASS, 14 equations verified)
- ✅ ML Dataset Generation (~5000 rows per seed)
- ✅ ML Model Training (6 classifiers, >90% accuracy)
- ✅ Review-2 Corrections (18 major defects fixed, FI-19 audit added)
- ✅ Documentation (this overview + reports)

**Status: READY FOR PHASE 2 / REVIEW-3 ML HEALTH CLASSIFICATION**

---

Generated: 2026-09-26  
Project Lead: Pranay Viswaraj  
Repository: https://github.com/PranayViswaraj/ARINC429
