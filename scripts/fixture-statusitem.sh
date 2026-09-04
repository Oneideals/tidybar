#!/usr/bin/env bash
# M0 用：造 N 个可预期的菜单栏图标，用来验证「枚举」与「⌘ 拖拽」的成功率。
# 用法：./scripts/fixture-statusitem.sh 6      （起 6 个图标，Ctrl+C 退出）
set -euo pipefail
cd "$(dirname "$0")/.."

COUNT="${1:-6}"
exec swift scripts/fixture-statusitem.swift "$COUNT"
