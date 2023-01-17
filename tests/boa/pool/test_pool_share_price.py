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

# fuzzing params - amount, Fees, initial share price 

# price always immediately decreases on divest and impair calls
# price always immediately increases if impairment burns accrued_fees
# price increases by X% if vesting_rate is Y
# price is X after Y profits realized (depends on fee struct)
# price is X after Y profits realized (depends on fee)
