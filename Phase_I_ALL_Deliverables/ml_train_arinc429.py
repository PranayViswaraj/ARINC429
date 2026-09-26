#!/usr/bin/env python3
# ml_train_arinc429.py - leakage-controlled training of six classifiers on the
# ARINC 429 fault-injection dataset (Phase-I, Review-3).
# Usage: python3 ml_train_arinc429.py arinc429_ml_dataset_seed1.csv

import argparse
import numpy as np
import pandas as pd
from sklearn.pipeline import Pipeline
from sklearn.impute import SimpleImputer
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import GroupShuffleSplit, GroupKFold
from sklearn.tree import DecisionTreeClassifier
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.svm import SVC
from sklearn.neighbors import KNeighborsClassifier
from sklearn.neural_network import MLPClassifier
from sklearn.metrics import (accuracy_score, balanced_accuracy_score,
                             f1_score, classification_report,
                             confusion_matrix)

RS = 42  # global random state for reproducibility

# Behavioural feature whitelist (Table 6.3): no identifiers, no injected
# ground truth, no cumulative run counters, no framework verdict columns.
FEATURES = [
    'parity_error', 'rx_word_mismatch', 'rx_valid', 'tx_done',
    'idle_duration', 'consecutive_error_count', 'error_rate_pct',
    'repeat_count', 'successful_transactions_between_errors',
    'window_size', 'window_faulty',
]
TARGET = 'health_label'


def load_data(paths):
    frames = [pd.read_csv(p) for p in paths]
    df = pd.concat(frames, ignore_index=True)
    # -1 is the dataset sentinel for 'not applicable': treat as missing so
    # that the median imputer (fitted on the train partition only) handles it.
    df[FEATURES] = df[FEATURES].replace(-1, np.nan)
    return df


def group_ids(df):
    # Partition-leakage guard: group rows by transaction lineage. Window,
    # event and reset rows group under their own identifiers.
    gid = (df['row_type'].astype(str) + '_' +
           np.select(
               [df['row_type'].eq(0), df['row_type'].eq(1),
                df['row_type'].eq(2)],
               [df['transaction_id'], df['window_id'], df['event_id']],
               default=df['sample_id']).astype(str))
    return gid


def make_models():
    return {
        'Decision tree': DecisionTreeClassifier(
            max_depth=8, min_samples_leaf=2, class_weight='balanced',
            random_state=RS),
        'Random forest': RandomForestClassifier(
            n_estimators=300, max_depth=12, class_weight='balanced',
            n_jobs=-1, random_state=RS),
        'Logistic regression': LogisticRegression(
            C=1.0, solver='lbfgs', max_iter=2000, class_weight='balanced'),
        'Support vector machine': SVC(
            kernel='rbf', C=10, gamma='scale', class_weight='balanced'),
        'K-nearest neighbours': KNeighborsClassifier(
            n_neighbors=5, weights='distance'),
        'Lightweight NN': MLPClassifier(
            hidden_layer_sizes=(32, 16), activation='relu', alpha=1e-4,
            max_iter=500, early_stopping=True, random_state=RS),
    }


def make_pipe(model):
    # Imputer and scaler live INSIDE the pipeline: they are fitted on the
    # training partition only and applied unchanged to the test partition.
    return Pipeline([
        ('impute', SimpleImputer(strategy='median')),
        ('scale', StandardScaler()),
        ('clf', model),
    ])


def evaluate(name, y_true, y_pred, labels):
    acc = accuracy_score(y_true, y_pred)
    bal = balanced_accuracy_score(y_true, y_pred)
    mf1 = f1_score(y_true, y_pred, labels=labels, average='macro',
                   zero_division=0)
    print(f'=== {name} ===')
    print(f'accuracy={acc:.4f}  balanced_accuracy={bal:.4f}  macro_f1={mf1:.4f}')
    print(classification_report(y_true, y_pred, labels=labels,
                                zero_division=0))
    print('confusion matrix (rows = true, cols = predicted):')
    print(confusion_matrix(y_true, y_pred, labels=labels))
    print()
    return {'model': name, 'accuracy': acc, 'balanced_accuracy': bal,
            'macro_f1': mf1}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('csv', nargs='+', help='dataset CSV file(s)')
    ap.add_argument('--holdout', type=float, default=0.20)
    args = ap.parse_args()

    df = load_data(args.csv)
    groups = group_ids(df)
    X, y = df[FEATURES], df[TARGET]
    labels = np.sort(df[TARGET].unique())

    # Group-wise holdout: whole transactions move together.
    gss = GroupShuffleSplit(n_splits=1, test_size=args.holdout,
                            random_state=RS)
    tr, te = next(gss.split(X, y, groups=groups))
    X_tr, X_te = X.iloc[tr], X.iloc[te]
    y_tr, y_te = y.iloc[tr], y.iloc[te]
    print(f'rows={len(df)}  train={len(tr)}  test={len(te)}  groups_test='
          f'{groups.iloc[te].nunique()}')

    results = []
    for name, model in make_models().items():
        pipe = make_pipe(model)
        pipe.fit(X_tr, y_tr)
        results.append(evaluate(name, y_te, pipe.predict(X_te), labels))

    # Robustness check: five-fold group-wise CV on the training partition.
    gkf = GroupKFold(n_splits=5)
    print('=== 5-fold GroupKFold (train partition) ===')
    for name, model in make_models().items():
        scores = []
        for k_tr, k_te in gkf.split(X_tr, y_tr, groups=groups.iloc[tr]):
            pipe = make_pipe(model)
            pipe.fit(X_tr.iloc[k_tr], y_tr.iloc[k_tr])
            pred = pipe.predict(X_tr.iloc[k_te])
            scores.append(balanced_accuracy_score(y_tr.iloc[k_te], pred))
        print(f'{name}: balanced_accuracy per fold = '
              f'{[round(s, 4) for s in scores]}')

    print('=== SUMMARY (holdout) ===')
    for res in results:
        print(f"{res['model']:24s} acc={res['accuracy']:.4f} "
              f"bal={res['balanced_accuracy']:.4f} "
              f"macro_f1={res['macro_f1']:.4f}")


if __name__ == '__main__':
    main()
