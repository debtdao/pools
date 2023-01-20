import boa
import ape
import pytest
import logging
from hypothesis import given, settings
from hypothesis import strategies as st
from datetime import timedelta
from math import exp


# https://docs.apeworx.io/ape/stable/methoddocs/managers.html?highlight=project#module-ape.managers.project.manager

# TODO Ask ChatGPT to generate test cases in vyper
# "price" definition = total_assets / total_supply in 4626 token. Price increase could be due to increase in assets or decrease in supply
# fuzzing params - amount, Fees, initial share price, vesting_rate ^v, vesting_time ^t = time between price change and blocktime when price tests get run

# 1. price always immediately decreases (asset decrease) on divest and impair calls if no accrued_fees
# 1. price always immediately increases (supply decrease) if impairment burns accrued_fees
# 1. price MUST NOT immediately increase (asset increase OR supply decrease) when fees earned (call unlock_profit before paying fees)

# 1. price increases by X% over Y time if vesting_rate is Z
# 1. price is X after Y profits realized (depends on fee struct)
# 1. price is X after Y profits realized (depends on fee)

# 1. APR should be 0% if locked_profit is 0
# 1. APR should be X% after Y revenue if vesting_rate is Z
# 1. APR should decrease by X% after L losses after Y revenue if vesting_rate is Z

# 1. calling unlock_profit() MUST increase share price if there are locked_profits and block.timestamp is > last_report
# 1. calling unlock_profit() MUST NOT share price if block.timestamp == last_report
# 1. calling unlock_profit() MUST update last_report to equal block.timestamp

# INVARIANTS
# 1. share price changes (+/-)  based on supply/assets
# 1. locked_profit^t = total_interest_earned * vesting_rate^t -- (t = 0, locked_profit = 0, t = 1, locked_profit = all_profit, t = 10, locked_profit = all_profit - vested_profit)
# 1. total_assets^t = total_assets + (total_interest_earned * vesting_rate^t) -- (t = 0, total_assets = total_assets, t = 1, total_assets + vested_profit = all_profit, t = 10, total_assets = total_assets + vested_profit)
# 1. price^t = total_assets^t / shares -- use derived total_assets^t from above