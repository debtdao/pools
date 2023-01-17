import boa
import boa
import ape
from boa.vyper.contract import BoaError
from hypothesis import given, settings
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, run_state_machine_as_test, rule, invariant
from datetime import timedelta

MAX_UINT = 115792089237316195423570985008687907853269984665640564039457584007913129639935
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"


# TODO Ask ChatGPT to generate test cases in vyper

# line of credit integration tests
# owner priviliges
# fee updates/settings

# @settings(max_examples=500, deadline=timedelta(seconds=1000))
# def test_owner_fees_burned_on_impairment(pool, me, admin):
    # with boa.prank(me):
        # pool


def test_assert_pool_constants(pool):
    """
    Test hardcoded constants in contract are what they're supposed to be
    """
    assert pool.INSOLVENT_STATUS() == 4     # index of INSOLVENT status in LineLib.STATUS enum
    assert pool.FEE_COEFFICIENT() == 10000  # 100% in bps
    assert pool.SNITCH_FEE() == 3000        # 30% in bps
    # @notice 5% in bps. Max fee that can be charged for non-performance fee
    assert pool.MAX_PITTANCE_FEE() == 200   # 2% in bps
    assert pool.CONTRACT_NAME() == 'Debt DAO Pool'
    assert pool.API_VERSION() == '0.0.001'  # dope that we can track contract version vs test for that version in source control
    # assert pool.DOMAIN_TYPE_HASH() == 0
    # assert pool.PERMIT_TYPE_HASH() == 0
    assert pool.DEGRADATION_COEFFICIENT() == 1e18

def test_assert_initial_pool_state(pool, base_asset, admin):
    """
    Test inital state of dummy testing pool contract.
    """
    assert pool.fees() == ( 0, 0, 0, 0, 0, 0 )
    assert pool.accrued_fees() == 0
    assert pool.min_deposit() == 0
    assert pool.total_deployed() == 0
    assert pool.owner() == admin
    assert pool.pending_owner() == ZERO_ADDRESS
    assert pool.fee_recipient() == admin
    assert pool.pending_fee_recipient() == ZERO_ADDRESS
    assert pool.max_assets() == MAX_UINT
    assert pool.asset() == base_asset.eval('self')
    assert pool.locked_profit() == 0
    assert pool.vesting_rate()== 46000000000000
    assert pool.last_report() == pool.eval('block.timestamp') # TODO what is block.timestamp in boa ??? 

    assert pool.totalSupply() == 0
    assert pool.total_assets()== 0

