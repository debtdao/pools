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
# fuzzing params - amount, Fees, initial share price 

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


