import boa
import boa
import ape
from boa.vyper.contract import BoaError
from hypothesis import given, settings
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, run_state_machine_as_test, rule, invariant
from datetime import timedelta


# TODO Ask ChatGPT to generate test cases in vyper

# line of credit integration tests
# owner priviliges
# fee updates/settings

# @settings(max_examples=500, deadline=timedelta(seconds=1000))
# def test_owner_fees_burned_on_impairment(pool_token, me, admin):
    # with boa.prank(me):
        # pool_token